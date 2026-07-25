import Fluent
import Foundation
import SQLKit
import Vapor

/// The migration control table predates the two sequence progress fields.
/// Fluent can leave those fields uninitialized when decoding the PostgreSQL
/// control record, so migration paths use this narrow durable projection.
struct ConversationShardMigrationSequenceProgress: Decodable, Sendable {
    let sourceCount: Int
    let copyWatermark: Int

    enum CodingKeys: String, CodingKey {
        case sourceCount = "source_domain_event_sequence_count"
        case copyWatermark = "copy_domain_event_sequence_watermark"
    }
}

enum ConversationShardMigrationSequenceProgressStore {
    static func load(
        conversationID: UUID,
        on database: any Database
    ) async throws -> ConversationShardMigrationSequenceProgress {
        guard let sql = database as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Conversation migration sequence progress requires an SQL primary database.")
        }
        guard let progress = try await sql.raw("""
            SELECT source_domain_event_sequence_count, copy_domain_event_sequence_watermark
            FROM conversation_shard_migrations
            WHERE conversation_id = \(bind: conversationID)
            """).first(decoding: ConversationShardMigrationSequenceProgress.self)
        else {
            throw Abort(.notFound, reason: "No prepared conversation shard migration exists for \(conversationID.uuidString).")
        }
        return progress
    }

    static func persistCopyWatermark(
        conversationID: UUID,
        watermark: Int,
        on database: any Database
    ) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Conversation migration sequence progress requires an SQL primary database.")
        }
        try await sql.raw("""
            UPDATE conversation_shard_migrations
            SET copy_domain_event_sequence_watermark = \(bind: watermark), updated_at = \(bind: Date())
            WHERE conversation_id = \(bind: conversationID)
            """).run()
    }
}
