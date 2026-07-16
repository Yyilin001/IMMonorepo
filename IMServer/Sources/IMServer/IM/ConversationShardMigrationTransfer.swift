import Crypto
import Foundation
import Vapor

enum IMCellConversationMigrationTransferKind: String, Codable, Content, Sendable, CaseIterable {
    case conversation
    case members
    case messages
    case domainEvents = "domain_events"
    case domainEventSequence = "domain_event_sequence"
    case recipientSnapshots = "recipient_snapshots"
    case timelineNotices = "timeline_notices"
    case mediaReferences = "media_references"
    case sideEffects = "side_effects"
}

/// Wire format for a single idempotent cross-Cell migration page. Records stay
/// individually encoded so a receiver can reject a malformed page before any
/// target-shard mutation is committed.
struct IMCellConversationMigrationTransferBatch: Content, Sendable {
    let conversationID: UUID
    let originCellID: String
    let targetCellID: String
    let targetShardID: String
    let sourceRouteVersion: Int
    let transferToken: String
    let kind: IMCellConversationMigrationTransferKind
    let records: [Data]
    let checksum: String

    static func checksum(for records: [Data]) -> String {
        var hasher = SHA256()
        for record in records {
            var length = UInt64(record.count).bigEndian
            withUnsafeBytes(of: &length) { bytes in
                hasher.update(data: Data(bytes))
            }
            hasher.update(data: record)
        }
        return Data(hasher.finalize()).map { String(format: "%02x", $0) }.joined()
    }
}

struct IMCellConversationMigrationTransferResponse: Content, Sendable {
    let importedCount: Int
    let alreadyPresentCount: Int
}

struct IMCellConversationMigrationVerificationRequest: Content, Sendable {
    let conversationID: UUID
    let originCellID: String
    let targetCellID: String
    let targetShardID: String
    let sourceRouteVersion: Int
    let transferToken: String
    let pageSize: Int
}

struct IMCellConversationMigrationVerificationResponse: Content, Sendable {
    let snapshot: ConversationShardMigrationPreflight.CanonicalDataSnapshot
    let fingerprint: String
    let sideEffectCount: Int
}

struct IMCellConversationMigrationFinalizeRequest: Content, Sendable {
    let conversationID: UUID
    let originCellID: String
    let targetCellID: String
    let targetShardID: String
    let sourceRouteVersion: Int
    let transferToken: String
    let cutoverLeaseToken: String
    let pageSize: Int
}
