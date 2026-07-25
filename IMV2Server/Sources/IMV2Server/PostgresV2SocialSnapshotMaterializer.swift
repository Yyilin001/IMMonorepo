import Crypto
import Fluent
import Foundation
import IMV2Core
import SQLKit

/// Builds the privacy-sensitive social portion of a reset snapshot directly
/// from PostgreSQL authority. It deliberately does not reconstruct message
/// history from today's room membership: history has per-recipient delivery
/// semantics. This is therefore a composable section, never a complete reset
/// stage on its own.
public struct V2AuthoritativeSocialSnapshot: Equatable, Sendable {
    public let baseSequence: UInt64
    public let pages: [V2SnapshotPageStage]

    public init(baseSequence: UInt64, pages: [V2SnapshotPageStage]) {
        self.baseSequence = baseSequence
        self.pages = pages
    }
}

/// PostgreSQL implementation for the mutable, device-independent social
/// projections.  The repeatable-read transaction aligns relationship, block,
/// preference and sync-watermark reads.  It never copies another user's block
/// rows into this user's snapshot.
public struct PostgresV2SocialSnapshotMaterializer: Sendable {
    private let database: any Database
    private let pageItemLimit: Int

    public init(
        database: any Database,
        pageItemLimit: Int = 500
    ) {
        precondition(pageItemLimit > 0)
        self.database = database
        self.pageItemLimit = pageItemLimit
    }

    public func materialize(userID: UserID, now: Date) async throws -> V2AuthoritativeSocialSnapshot {
        let userUUID = try snapshotUUID(userID)
        let social = try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2SnapshotMaterializerError.corruptPersistenceState }
            // A snapshot must not combine social rows from different commits
            // with a watermark from a third commit.
            try await sql.raw("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY").run()
            let watermark = try await sql.raw("""
                SELECT COALESCE((SELECT next_sequence FROM im_v2.user_sync_sequences
                                 WHERE user_id = \(bind: userUUID)), 0) AS value
                """).first(decoding: SnapshotWatermarkRow.self)?.value ?? 0
            let relationships = try await sql.raw("""
                SELECT CASE WHEN lower_user_id = \(bind: userUUID) THEN higher_user_id ELSE lower_user_id END AS target_user_id,
                       state,
                       CASE WHEN state = 'pending' THEN requested_by_user_id ELSE NULL END AS requested_by_user_id,
                       updated_at
                FROM im_v2.user_relationships
                WHERE lower_user_id = \(bind: userUUID) OR higher_user_id = \(bind: userUUID)
                ORDER BY target_user_id
                """).all(decoding: SnapshotRelationshipRow.self)
            let blocks = try await sql.raw("""
                SELECT blocked_user_id AS target_user_id, created_at AS updated_at
                FROM im_v2.user_blocks
                WHERE blocker_user_id = \(bind: userUUID)
                ORDER BY blocked_user_id
                """).all(decoding: SnapshotBlockRow.self)
            let preference = try await sql.raw("""
                SELECT allows_stranger_messages, updated_at
                FROM im_v2.user_stranger_message_preferences
                WHERE user_id = \(bind: userUUID)
                """).first(decoding: SnapshotPreferenceRow.self)
            return (watermark, relationships, blocks, preference)
        }

        guard social.0 >= 0 else { throw V2SnapshotMaterializerError.corruptPersistenceState }
        let relationships = try social.1.map { row -> V2SnapshotRelationshipProjection in
            guard let state = V2RelationshipState(rawValue: row.state) else { throw V2SnapshotMaterializerError.corruptPersistenceState }
            return try .init(targetUserID: .init(row.targetUserID.uuidString), state: state, requestedByUserID: try row.requestedByUserID.map { try .init($0.uuidString) }, updatedAt: row.updatedAt)
        }
        let blocks = try social.2.map { row in
            V2SnapshotUserBlockProjection(targetUserID: try .init(row.targetUserID.uuidString), isBlocked: true, updatedAt: row.updatedAt)
        }
        let preference = V2SnapshotStrangerMessagePreference(
            allowsStrangerMessages: social.3?.allowsStrangerMessages ?? true,
            updatedAt: social.3?.updatedAt ?? now
        )
        let pages = try makePages(relationships: relationships, blocks: blocks, preference: preference)
        return .init(baseSequence: UInt64(social.0), pages: pages.map { .init(digest: snapshotSHA256($0), payload: $0) })
    }

    private func makePages(
        relationships: [V2SnapshotRelationshipProjection],
        blocks: [V2SnapshotUserBlockProjection],
        preference: V2SnapshotStrangerMessagePreference
    ) throws -> [Data] {
        var relationshipOffset = 0
        var blockOffset = 0
        var pages: [Data] = []
        repeat {
            var remaining = pageItemLimit
            let relationshipEnd = min(relationships.count, relationshipOffset + remaining)
            let pageRelationships = Array(relationships[relationshipOffset..<relationshipEnd])
            relationshipOffset = relationshipEnd
            remaining -= pageRelationships.count
            let blockEnd = min(blocks.count, blockOffset + remaining)
            let pageBlocks = Array(blocks[blockOffset..<blockEnd])
            blockOffset = blockEnd
            pages.append(try V2SnapshotProjectionCodec.encode(.init(
                messages: [],
                relationships: pageRelationships,
                userBlocks: pageBlocks,
                strangerMessagePreference: pages.isEmpty ? preference : nil,
                moderationActions: [],
                roomControls: []
            )))
        } while relationshipOffset < relationships.count || blockOffset < blocks.count
        return pages
    }
}

public enum V2SnapshotMaterializerError: Error, Equatable, Sendable {
    case corruptPersistenceState
}

private struct SnapshotWatermarkRow: Decodable { let value: Int64 }
private struct SnapshotRelationshipRow: Decodable {
    let targetUserID: UUID
    let state: String
    let requestedByUserID: UUID?
    let updatedAt: Date
    enum CodingKeys: String, CodingKey {
        case targetUserID = "target_user_id"
        case state
        case requestedByUserID = "requested_by_user_id"
        case updatedAt = "updated_at"
    }
}
private struct SnapshotBlockRow: Decodable {
    let targetUserID: UUID
    let updatedAt: Date
    enum CodingKeys: String, CodingKey { case targetUserID = "target_user_id"; case updatedAt = "updated_at" }
}
private struct SnapshotPreferenceRow: Decodable {
    let allowsStrangerMessages: Bool
    let updatedAt: Date
    enum CodingKeys: String, CodingKey { case allowsStrangerMessages = "allows_stranger_messages"; case updatedAt = "updated_at" }
}

private func snapshotUUID<Tag>(_ value: V2Identifier<Tag>) throws -> UUID where Tag: V2IdentifierTag {
    guard let result = UUID(uuidString: value.rawValue) else { throw V2SnapshotMaterializerError.corruptPersistenceState }
    return result
}

private func snapshotSHA256(_ bytes: Data) -> String {
    SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
}
