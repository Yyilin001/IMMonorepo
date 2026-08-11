import Fluent
import Foundation
import IMV2Core
import SQLKit

/// Multi-forward is intentionally a sequence of independently durable pairs.
/// A target may be unavailable without discarding successful targets, while a
/// durable client-message ID makes every pair retry-safe across a crash between
/// the operation row and normal message acceptance transaction.
public struct V2ForwardMessagesService: Sendable {
    private let database: any Database
    private let writeStore: any V2RoomWriteStore
    private let capacityProfile: V2CapacityProfile
    private let limits: V2MessageCommandLimits
    private let acceptanceIDs: V2AcceptanceIDFactory
    private let makeUUID: @Sendable () -> UUID
    private let now: @Sendable () -> Date

    public init(database: any Database, writeStore: any V2RoomWriteStore, capacityProfile: V2CapacityProfile, limits: V2MessageCommandLimits, acceptanceIDs: V2AcceptanceIDFactory = .init(), makeUUID: @escaping @Sendable () -> UUID = UUID.init, now: @escaping @Sendable () -> Date = Date.init) {
        self.database = database; self.writeStore = writeStore; self.capacityProfile = capacityProfile; self.limits = limits; self.acceptanceIDs = acceptanceIDs; self.makeUUID = makeUUID; self.now = now
    }

    public func forward(actorUserID: UserID, command: V2ForwardMessagesCommand) async throws -> [V2ForwardMessageResult] {
        var results: [V2ForwardMessageResult] = []
        for source in command.sourceMessageIDs {
            let content: ForwardSourceContent
            do { content = try await readSource(messageID: source, actorUserID: actorUserID) }
            catch { results += command.targetRoomIDs.map { .init(sourceMessageID: source, targetRoomID: $0, messageID: nil, roomSequence: nil, errorCode: forwardErrorCode(error)) }; continue }
            for target in command.targetRoomIDs {
                do {
                    let clientID = try await clientMessageID(actor: actorUserID, operation: command.operationID, source: source, target: target)
                    let request = try V2SendMessageCommand(roomID: target, senderUserID: actorUserID, clientMessageID: clientID, text: content.text, media: content.media, entities: content.entities, forwardedFrom: .init(messageID: source, senderUserID: content.senderUserID), limits: limits)
                    let outcome = try await writeStore.accept(command: request, capacityProfile: capacityProfile, identifiers: try acceptanceIDs.make(), now: now())
                    switch outcome {
                    case .accepted(let message), .idempotent(let message):
                        try await markResult(actor: actorUserID, operation: command.operationID, source: source, target: target, message: message.messageID)
                        results.append(.init(sourceMessageID: source, targetRoomID: target, messageID: message.messageID, roomSequence: message.roomSequence, errorCode: nil))
                    case .idempotencyConflict: results.append(.init(sourceMessageID: source, targetRoomID: target, messageID: nil, roomSequence: nil, errorCode: "IDEMPOTENCY_CONFLICT"))
                    case .denied: results.append(.init(sourceMessageID: source, targetRoomID: target, messageID: nil, roomSequence: nil, errorCode: "DIRECT_MESSAGE_RESTRICTED"))
                    case .rateLimited: results.append(.init(sourceMessageID: source, targetRoomID: target, messageID: nil, roomSequence: nil, errorCode: "RATE_LIMITED"))
                    case .unavailable: results.append(.init(sourceMessageID: source, targetRoomID: target, messageID: nil, roomSequence: nil, errorCode: "UNAVAILABLE"))
                    }
                } catch { results.append(.init(sourceMessageID: source, targetRoomID: target, messageID: nil, roomSequence: nil, errorCode: forwardErrorCode(error))) }
            }
        }
        return results
    }

    private func readSource(messageID: MessageID, actorUserID: UserID) async throws -> ForwardSourceContent {
        guard let sql = database as? any SQLDatabase, let message = UUID(uuidString: messageID.rawValue), let actor = UUID(uuidString: actorUserID.rawValue) else { throw V2ForwardStoreError.corrupt }
        guard let row = try await sql.raw("SELECT message.sender_user_id, message.text_body, message.rich_entities::text AS entities_json, room.membership_revision FROM im_v2.messages AS message INNER JOIN im_v2.rooms AS room ON room.room_id = message.room_id WHERE message.message_id = \(bind: message) AND message.withdrawn_at IS NULL AND EXISTS (SELECT 1 FROM im_v2.room_memberships AS membership WHERE membership.room_id = message.room_id AND membership.user_id = \(bind: actor) AND membership.joined_revision <= room.membership_revision AND (membership.left_revision IS NULL OR membership.left_revision > room.membership_revision))").first(decoding: ForwardSourceRow.self) else { throw V2ForwardStoreError.notVisible }
        let media = try await sql.raw("SELECT media_id FROM im_v2.message_media_references WHERE message_id = \(bind: message) AND revoked_at IS NULL ORDER BY ordinal").all(decoding: ForwardMediaRow.self).map { try V2MediaReference(mediaID: .init($0.mediaID.uuidString)) }
        let entities = try JSONDecoder().decode([V2MessageEntity].self, from: Data(row.entitiesJSON.utf8))
        return try .init(senderUserID: .init(row.senderUserID.uuidString), text: row.text, media: media, entities: entities)
    }

    private func clientMessageID(actor: UserID, operation: MessageForwardOperationID, source: MessageID, target: RoomID) async throws -> ClientMessageID {
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase, let actor = UUID(uuidString: actor.rawValue), let operation = UUID(uuidString: operation.rawValue), let source = UUID(uuidString: source.rawValue), let target = UUID(uuidString: target.rawValue) else { throw V2ForwardStoreError.corrupt }
            if let prior = try await sql.raw("SELECT target_client_message_id FROM im_v2.message_forward_operations WHERE actor_user_id = \(bind: actor) AND operation_id = \(bind: operation) AND source_message_id = \(bind: source) AND target_room_id = \(bind: target)").first(decoding: ForwardOperationRow.self) { return try .init(prior.clientMessageID.uuidString) }
            let client = makeUUID()
            try await sql.raw("INSERT INTO im_v2.message_forward_operations (actor_user_id, operation_id, source_message_id, target_room_id, target_client_message_id, created_at) VALUES (\(bind: actor), \(bind: operation), \(bind: source), \(bind: target), \(bind: client), \(bind: now()))").run()
            return try .init(client.uuidString)
        }
    }

    private func markResult(actor: UserID, operation: MessageForwardOperationID, source: MessageID, target: RoomID, message: MessageID) async throws {
        guard let sql = database as? any SQLDatabase, let actor = UUID(uuidString: actor.rawValue), let operation = UUID(uuidString: operation.rawValue), let source = UUID(uuidString: source.rawValue), let target = UUID(uuidString: target.rawValue), let message = UUID(uuidString: message.rawValue) else { throw V2ForwardStoreError.corrupt }
        try await sql.raw("UPDATE im_v2.message_forward_operations SET result_message_id = \(bind: message) WHERE actor_user_id = \(bind: actor) AND operation_id = \(bind: operation) AND source_message_id = \(bind: source) AND target_room_id = \(bind: target)").run()
    }
}

private struct ForwardSourceContent { let senderUserID: UserID; let text: String; let media: [V2MediaReference]; let entities: [V2MessageEntity] }
private struct ForwardSourceRow: Decodable { let senderUserID: UUID; let text: String; let entitiesJSON: String; let membershipRevision: Int64; enum CodingKeys: String, CodingKey { case senderUserID = "sender_user_id", text = "text_body", entitiesJSON = "entities_json", membershipRevision = "membership_revision" } }
private struct ForwardMediaRow: Decodable { let mediaID: UUID; enum CodingKeys: String, CodingKey { case mediaID = "media_id" } }
private struct ForwardOperationRow: Decodable { let clientMessageID: UUID; enum CodingKeys: String, CodingKey { case clientMessageID = "target_client_message_id" } }
private enum V2ForwardStoreError: Error { case notVisible, corrupt }
private func forwardErrorCode(_ error: Error) -> String { switch error { case V2ForwardStoreError.notVisible: "NOT_FOUND"; case V2RoomWriteStoreError.actorNotEligible: "FORBIDDEN"; case V2RoomWriteStoreError.roomNotFound: "NOT_FOUND"; default: "UNAVAILABLE" } }
