import Foundation
import IMV2Core
import SQLKit

// Validates source-version authority and locks media on the caller's
// transaction connection before scalar message persistence.
enum RoomWriteMediaAcceptance {
    static func presentations(
        command: V2SendMessageCommand,
        importedForward: ForwardInboxAuthorization?,
        forwardSourceRoomID: UUID?,
        senderID: UUID,
        now: Date,
        sql: any SQLDatabase
    ) async throws -> [V2MediaPresentation] {
        let mediaAuthority: MessageMediaAcceptanceAuthority
        if let importedForward {
            let exact = try importedForward.command(limits: .init(maxUTF8Bytes: max(importedForward.export.intent.text.utf8.count, 1)))
            guard command == exact else { throw V2ForwardInboxError.idempotencyConflict }
            // Imported files are separate target-owned objects. An inbox
            // mapping does not grant access to arbitrary source media IDs.
            mediaAuthority = .ownedBy(senderID)
        } else if let forwarded = command.forwardedFrom {
            guard let sourceMessageID = UUID(uuidString: forwarded.messageID.rawValue),
                  let sourceSenderID = UUID(uuidString: forwarded.senderUserID.rawValue),
                  let source = try await sql.raw("""
                      SELECT message.room_id, message.sender_user_id, message.text_body,
                             message.withdrawn_at, message.content_revision, message.rich_entities::text AS entities_json
                      FROM im_v2.messages AS message
                      INNER JOIN im_v2.rooms AS room ON room.room_id = message.room_id
                      WHERE message.message_id = \(bind: sourceMessageID)
                        AND (\(v2ForwardSourceVisibility(actorID: senderID)))
                      FOR UPDATE OF message
                      """).first(decoding: ForwardSourceRow.self),
                  source.roomID == forwardSourceRoomID,
                  source.contentRevision == forwarded.sourceRevision.signedValue,
                  source.senderUserID == sourceSenderID, source.withdrawnAt == nil,
                  source.text == command.text,
                  try JSONDecoder().decode([V2MessageEntity].self, from: Data(source.entitiesJSON.utf8)) == command.entities
            else { throw V2RoomWriteStoreError.actorNotEligible }
            // A forward may only reuse an attachment from the exact
            // source message; attribution is not a general media grant.
            let sourceReferences = try await sql.raw("""
                SELECT media_id, ordinal, revoked_at FROM im_v2.message_media_references
                WHERE message_id = \(bind: sourceMessageID)
                ORDER BY media_id FOR SHARE
                """).all(decoding: ForwardMediaRow.self)
            let sourceMedia = sourceReferences.sorted { $0.ordinal < $1.ordinal }.map(\.mediaID)
            guard sourceReferences.allSatisfy({ $0.revokedAt == nil }),
                  sourceMedia == (try command.media.map { try mediaAcceptanceUUID($0.mediaID) })
            else { throw V2RoomWriteStoreError.actorNotEligible }
            mediaAuthority = .forwardedFrom(sourceMessageID)
        } else { mediaAuthority = .ownedBy(senderID) }
        let mediaPresentations = try await assertAvailableMedia(command.media, authority: mediaAuthority, now: now, sql: sql)
        if let importedForward {
            guard mediaPresentations.count == importedForward.export.intent.media.count,
                  zip(mediaPresentations, importedForward.export.intent.media).allSatisfy({ actual, expected in
                      actual.contentType == expected.contentType && actual.byteCount == expected.byteCount
                  })
            else { throw V2MediaStoreError.mediaUnavailable }
        }
        return mediaPresentations
    }

    private static func assertAvailableMedia(_ media: [V2MediaReference], authority: MessageMediaAcceptanceAuthority, now: Date, sql: any SQLDatabase) async throws -> [V2MediaPresentation] {
        guard !media.isEmpty else { return [] }
        guard Set(media).count == media.count else { throw V2MediaStoreError.invalidReferenceSet }
        let requested = try media.enumerated().map { ordinal, reference in
            OrderedMediaReferenceInput(ordinal: ordinal, mediaID: try mediaAcceptanceUUID(reference.mediaID))
        }
        let authorization: SQLQueryString = switch authority {
        case .ownedBy(let ownerID):
            "media.owner_user_id = \(bind: ownerID)"
        case .forwardedFrom(let sourceMessageID):
            // The caller has locked and authorized this exact source/version
            // and its complete reference set. A later-hop sender need not own
            // the original asset; the active source reference is the grant.
            """
            EXISTS (
                SELECT 1 FROM im_v2.message_media_references AS source_reference
                WHERE source_reference.message_id = \(bind: sourceMessageID)
                  AND source_reference.media_id = media.media_id
                  AND source_reference.revoked_at IS NULL
            )
            """
        }
        let requestedJSON = try roomWriteJSON(requested)
        let rows = try await sql.raw("""
            WITH requested AS (
                SELECT ordinal, media_id
                FROM jsonb_to_recordset(\(bind: requestedJSON)::jsonb)
                     AS input(ordinal integer, media_id uuid)
            )
            SELECT requested.ordinal, media.media_id, media.content_type, media.byte_count
            FROM requested
            JOIN im_v2.media_objects AS media
              ON media.media_id = requested.media_id
             AND (\(authorization))
             AND media.state = 'available'
             AND media.expires_at > \(bind: now)
            -- Lock shared media in a canonical order so two concurrent sends
            -- cannot deadlock merely because their attachment order differs.
            ORDER BY media.media_id
            FOR UPDATE OF media
            """).all(decoding: OrderedMessageMediaPresentationRow.self)
        let orderedRows = rows.sorted { $0.ordinal < $1.ordinal }
        guard orderedRows.count == requested.count,
              orderedRows.enumerated().allSatisfy({ $0.offset == $0.element.ordinal })
        else { throw V2MediaStoreError.mediaUnavailable }
        return try orderedRows.map { try $0.presentation }
    }
}

private func mediaAcceptanceUUID<Tag>(_ value: V2Identifier<Tag>) throws -> UUID where Tag: V2IdentifierTag {
    guard let value = value.uuidValue else { throw V2RoomWriteStoreError.corruptPersistenceState }
    return value
}

private struct OrderedMessageMediaPresentationRow: Decodable {
    let ordinal: Int
    let mediaID: UUID
    let contentType: String
    let byteCount: Int64

    enum CodingKeys: String, CodingKey {
        case ordinal
        case mediaID = "media_id"
        case contentType = "content_type"
        case byteCount = "byte_count"
    }

    var presentation: V2MediaPresentation {
        get throws {
            try .init(
                mediaID: .init(uuid: mediaID),
                kind: V2MediaPresentation.kind(forContentType: contentType),
                contentType: contentType,
                byteCount: byteCount
            )
        }
    }
}

private struct ForwardSourceRow: Decodable { let roomID: UUID; let senderUserID: UUID; let text: String; let withdrawnAt: Date?; let entitiesJSON: String; let contentRevision: Int64; enum CodingKeys: String, CodingKey { case contentRevision = "content_revision", roomID = "room_id", senderUserID = "sender_user_id", text = "text_body", withdrawnAt = "withdrawn_at", entitiesJSON = "entities_json" } }
private enum MessageMediaAcceptanceAuthority: Sendable {
    case ownedBy(UUID)
    case forwardedFrom(UUID)
}
private struct ForwardMediaRow: Decodable {
    let mediaID: UUID
    let ordinal: Int
    let revokedAt: Date?
    enum CodingKeys: String, CodingKey { case mediaID = "media_id", ordinal, revokedAt = "revoked_at" }
}
