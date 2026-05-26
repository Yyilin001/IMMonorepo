import Fluent
import Foundation
import SQLKit
import Vapor

struct ConversationSearchIndexWorker {
    let db: any Database

    func reindexMessage(messageID: UUID, on database: (any Database)? = nil) async throws {
        let database = database ?? db
        let recordID = ConversationMessageSearchIndex.recordID(messageID: messageID)

        guard let message = try await ConversationMessage.find(messageID, on: database) else {
            if let existing = try await ConversationMessageSearchIndex.find(recordID, on: database) {
                try await existing.delete(on: database)
            }
            return
        }

        let aggregate = try message.decodedAggregate()
        let content = try message.decodedContent()
        let searchableText = MessagePresentation(aggregate: aggregate)
            .searchableTexts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        let contentJSON = try Self.encode(content)
        let derivedStateJSON = try Self.encode(aggregate.derivedState)
        let updatedAt = Date()
        let createdAt = message.createdAt ?? updatedAt

        if let existing = try await ConversationMessageSearchIndex.find(recordID, on: database) {
            existing.conversationID = message.$conversation.id
            existing.messageID = messageID
            existing.serverSequence = message.serverSequence
            existing.messageType = message.kind
            existing.senderUserID = message.$sender.id
            existing.searchableText = searchableText
            existing.contentJSON = contentJSON
            existing.derivedStateJSON = derivedStateJSON
            existing.updatedAt = updatedAt
            try await existing.update(on: database)
        } else {
            let index = ConversationMessageSearchIndex(
                messageID: messageID,
                conversationID: message.$conversation.id,
                serverSequence: message.serverSequence,
                messageType: message.kind,
                senderUserID: message.$sender.id,
                searchableText: searchableText,
                contentJSON: contentJSON,
                derivedStateJSON: derivedStateJSON,
                createdAt: createdAt,
                updatedAt: updatedAt
            )
            try await index.create(on: database)
        }
    }

    func reindexMessages(messageIDs: [UUID], on database: (any Database)? = nil) async throws {
        let database = database ?? db
        let uniqueMessageIDs = Array(Set(messageIDs)).sorted { $0.uuidString < $1.uuidString }
        guard !uniqueMessageIDs.isEmpty else {
            return
        }

        let messages = try await ConversationMessage.query(on: database)
            .filter(\.$id ~~ uniqueMessageIDs)
            .all()
        guard !messages.isEmpty else {
            return
        }

        guard let sql = database as? any SQLDatabase else {
            for message in messages {
                try await reindexMessage(messageID: try message.requireID(), on: database)
            }
            return
        }

        let updatedAt = Date()
        let rows = try messages.map { message -> SearchIndexUpsertRow in
            let messageID = try message.requireID()
            let aggregate = try message.decodedAggregate()
            let content = try message.decodedContent()
            let searchableText = MessagePresentation(aggregate: aggregate)
                .searchableTexts
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            return SearchIndexUpsertRow(
                id: ConversationMessageSearchIndex.recordID(messageID: messageID),
                conversationID: message.$conversation.id,
                messageID: messageID,
                serverSequence: message.serverSequence,
                messageType: message.kind,
                senderUserID: message.$sender.id,
                searchableText: searchableText,
                contentJSON: try Self.encode(content),
                derivedStateJSON: try Self.encode(aggregate.derivedState),
                createdAt: message.createdAt ?? updatedAt,
                updatedAt: updatedAt
            )
        }

        let values = rows.map { row in
            """
            (
                \(bind: row.id),
                \(bind: row.conversationID),
                \(bind: row.messageID),
                \(bind: row.serverSequence),
                \(bind: row.messageType),
                \(bind: row.senderUserID),
                \(bind: row.searchableText),
                \(bind: row.contentJSON),
                \(bind: row.derivedStateJSON),
                \(bind: row.createdAt),
                \(bind: row.updatedAt)
            )
            """ as SQLQueryString
        }.joined(separator: ", ")

        try await sql.raw("""
            INSERT INTO \(ident: ConversationMessageSearchIndex.schema) (
                \(ident: "id"),
                \(ident: "conversation_id"),
                \(ident: "message_id"),
                \(ident: "server_sequence"),
                \(ident: "message_type"),
                \(ident: "sender_user_id"),
                \(ident: "searchable_text"),
                \(ident: "content_json"),
                \(ident: "derived_state_json"),
                \(ident: "created_at"),
                \(ident: "updated_at")
            )
            VALUES \(values)
            ON CONFLICT (\(ident: "id")) DO UPDATE SET
                \(ident: "conversation_id") = \(ident: "excluded").\(ident: "conversation_id"),
                \(ident: "message_id") = \(ident: "excluded").\(ident: "message_id"),
                \(ident: "server_sequence") = \(ident: "excluded").\(ident: "server_sequence"),
                \(ident: "message_type") = \(ident: "excluded").\(ident: "message_type"),
                \(ident: "sender_user_id") = \(ident: "excluded").\(ident: "sender_user_id"),
                \(ident: "searchable_text") = \(ident: "excluded").\(ident: "searchable_text"),
                \(ident: "content_json") = \(ident: "excluded").\(ident: "content_json"),
                \(ident: "derived_state_json") = \(ident: "excluded").\(ident: "derived_state_json"),
                \(ident: "updated_at") = \(ident: "excluded").\(ident: "updated_at")
            """).run()
    }

    private static func encode(_ content: IMMessageContent) throws -> String {
        try content.protobuf.serializedData().base64EncodedString()
    }

    private static func encode(_ derivedState: IMMessageDerivedState) throws -> String {
        try derivedState.protobuf.serializedData().base64EncodedString()
    }
}

private struct SearchIndexUpsertRow {
    let id: String
    let conversationID: UUID
    let messageID: UUID
    let serverSequence: Int
    let messageType: String
    let senderUserID: UUID
    let searchableText: String
    let contentJSON: String
    let derivedStateJSON: String
    let createdAt: Date
    let updatedAt: Date
}
