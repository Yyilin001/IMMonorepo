import Fluent
import Foundation
import SQLKit

struct ConversationNotificationBatchWriter {
    struct Row {
        let ownerUserID: UUID
        let eventID: UUID
        let conversationID: UUID
        let eventType: String
        let payload: ConversationDomainEventPayload
        let createdAt: Date
        let updatedAt: Date

        var id: String {
            ConversationNotificationEntry.recordID(ownerUserID: ownerUserID, eventID: eventID)
        }
    }

    let database: any Database

    func upsert(_ rows: [Row]) async throws {
        guard !rows.isEmpty else {
            return
        }

        guard let sql = database as? any SQLDatabase else {
            for row in rows {
                if let existing = try await ConversationNotificationEntry.find(row.id, on: database) {
                    existing.ownerUserID = row.ownerUserID
                    existing.eventID = row.eventID
                    existing.conversationID = row.conversationID
                    existing.eventType = row.eventType
                    existing.payload = row.payload
                    existing.updatedAt = row.updatedAt
                    try await existing.update(on: database)
                } else {
                    try await ConversationNotificationEntry(
                        ownerUserID: row.ownerUserID,
                        eventID: row.eventID,
                        conversationID: row.conversationID,
                        eventType: row.eventType,
                        payload: row.payload,
                        createdAt: row.createdAt,
                        updatedAt: row.updatedAt
                    ).create(on: database)
                }
            }
            return
        }

        let values = try rows.map { row -> SQLQueryString in
            let payloadJSON = try Self.encode(row.payload)
            return """
            (
                \(bind: row.id),
                \(bind: row.ownerUserID),
                \(bind: row.eventID),
                \(bind: row.conversationID),
                \(bind: row.eventType),
                \(bind: payloadJSON),
                \(bind: row.createdAt),
                \(bind: row.updatedAt)
            )
            """ as SQLQueryString
        }.joined(separator: ", ")

        try await sql.raw("""
            INSERT INTO \(ident: ConversationNotificationEntry.schema) (
                \(ident: "id"),
                \(ident: "owner_user_id"),
                \(ident: "event_id"),
                \(ident: "conversation_id"),
                \(ident: "event_type"),
                \(ident: "payload_json"),
                \(ident: "created_at"),
                \(ident: "updated_at")
            )
            VALUES \(values)
            ON CONFLICT (\(ident: "id")) DO UPDATE SET
                \(ident: "owner_user_id") = \(ident: "excluded").\(ident: "owner_user_id"),
                \(ident: "event_id") = \(ident: "excluded").\(ident: "event_id"),
                \(ident: "conversation_id") = \(ident: "excluded").\(ident: "conversation_id"),
                \(ident: "event_type") = \(ident: "excluded").\(ident: "event_type"),
                \(ident: "payload_json") = \(ident: "excluded").\(ident: "payload_json"),
                \(ident: "updated_at") = \(ident: "excluded").\(ident: "updated_at")
            """).run()
    }

    private static func encode(_ payload: ConversationDomainEventPayload) throws -> String {
        let data = try JSONEncoder().encode(payload)
        guard let json = String(data: data, encoding: .utf8) else {
            throw ConversationProjectionCodingError.invalidJSON
        }
        return json
    }
}
