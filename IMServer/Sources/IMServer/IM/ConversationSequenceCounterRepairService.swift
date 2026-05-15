import Fluent
import SQLKit
import Vapor

struct ConversationSequenceCounterRepairService {
    let db: any Database

    @discardableResult
    func reconcileLastMessageSequences() async throws -> Int {
        guard let sql = db as? any SQLDatabase else {
            return try await reconcileWithFluent()
        }

        switch sql.dialect.name {
        case "postgresql":
            try await sql.raw("""
                UPDATE \(ident: Conversation.schema) AS \(ident: "conversation")
                SET \(ident: "last_message_sequence") = GREATEST(
                    \(ident: "conversation").\(ident: "last_message_sequence"),
                    COALESCE((
                        SELECT MAX(\(ident: "message").\(ident: "server_sequence"))
                        FROM \(ident: ConversationMessage.schema) AS \(ident: "message")
                        WHERE \(ident: "message").\(ident: "conversation_id") = \(ident: "conversation").\(ident: "id")
                    ), 0)
                )
                """).run()
            return 0

        case "sqlite":
            try await sql.raw("""
                UPDATE \(ident: Conversation.schema)
                SET \(ident: "last_message_sequence") = MAX(
                    \(ident: "last_message_sequence"),
                    COALESCE((
                        SELECT MAX(\(ident: "server_sequence"))
                        FROM \(ident: ConversationMessage.schema)
                        WHERE \(ident: "conversation_id") = \(ident: Conversation.schema).\(ident: "id")
                    ), 0)
                )
                """).run()
            return 0

        default:
            return try await reconcileWithFluent()
        }
    }

    private func reconcileWithFluent() async throws -> Int {
        let conversations = try await Conversation.query(on: db).all()
        var updatedCount = 0
        for conversation in conversations {
            let conversationID = try conversation.requireID()
            let latestPersistedMessageSequence = try await ConversationMessage.query(on: db)
                .filter(\.$conversation.$id == conversationID)
                .sort(\.$serverSequence, .descending)
                .first()?
                .serverSequence ?? 0
            guard latestPersistedMessageSequence > conversation.lastMessageSequence else {
                continue
            }
            conversation.lastMessageSequence = latestPersistedMessageSequence
            try await conversation.update(on: db)
            updatedCount += 1
        }
        return updatedCount
    }
}
