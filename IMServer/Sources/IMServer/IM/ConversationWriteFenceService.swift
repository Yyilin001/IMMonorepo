import Fluent
import SQLKit
import Vapor

/// Locks the source-shard fence row for the duration of a canonical write.
/// PostgreSQL receives a real `FOR UPDATE` row lock; SQLite test deployments
/// rely on their transaction writer serialization. The caller must invoke this
/// inside the same transaction that mutates canonical conversation state.
struct ConversationWriteFenceService {
    static func ensureWritableFence(
        conversationID: UUID,
        on database: any Database
    ) async throws {
        if try await ConversationWriteFence.find(conversationID, on: database) == nil {
            do {
                try await ConversationWriteFence(conversationID: conversationID).create(on: database)
            } catch {
                guard try await ConversationWriteFence.find(conversationID, on: database) != nil else {
                    throw error
                }
            }
        }
    }

    static func requireWritesAllowed(
        conversationID: UUID,
        on database: any Database
    ) async throws {
        try await ensureWritableFence(conversationID: conversationID, on: database)
        if let sql = database as? any SQLDatabase,
           sql.dialect.name == "postgresql" {
            try await sql.raw("""
                SELECT conversation_id
                FROM conversation_write_fences
                WHERE conversation_id = \(bind: conversationID)
                FOR UPDATE
                """).run()
        }
        guard let fence = try await ConversationWriteFence.find(conversationID, on: database),
              fence.stateEnum == .writable
        else {
            throw Abort(.conflict, reason: "Conversation is fenced for shard migration; retry after routing completes.")
        }
    }

    static func blockWrites(
        conversationID: UUID,
        on database: any Database
    ) async throws {
        try await database.transaction { transaction in
            try await ensureWritableFence(conversationID: conversationID, on: transaction)
            if let sql = transaction as? any SQLDatabase,
               sql.dialect.name == "postgresql" {
                try await sql.raw("""
                    SELECT conversation_id
                    FROM conversation_write_fences
                    WHERE conversation_id = \(bind: conversationID)
                    FOR UPDATE
                    """).run()
            }
            guard let fence = try await ConversationWriteFence.find(conversationID, on: transaction) else {
                throw Abort(.internalServerError, reason: "Conversation write fence was not created.")
            }
            guard fence.stateEnum == .writable else { return }
            fence.stateEnum = .blocked
            fence.epoch += 1
            fence.updatedAt = Date()
            try await fence.update(on: transaction)
        }
    }

    static func unblockWrites(
        conversationID: UUID,
        on database: any Database
    ) async throws {
        try await database.transaction { transaction in
            try await ensureWritableFence(conversationID: conversationID, on: transaction)
            if let sql = transaction as? any SQLDatabase,
               sql.dialect.name == "postgresql" {
                try await sql.raw("""
                    SELECT conversation_id
                    FROM conversation_write_fences
                    WHERE conversation_id = \(bind: conversationID)
                    FOR UPDATE
                    """).run()
            }
            guard let fence = try await ConversationWriteFence.find(conversationID, on: transaction) else {
                throw Abort(.internalServerError, reason: "Conversation write fence was not created.")
            }
            guard fence.stateEnum == .blocked else { return }
            fence.stateEnum = .writable
            fence.updatedAt = Date()
            try await fence.update(on: transaction)
        }
    }
}
