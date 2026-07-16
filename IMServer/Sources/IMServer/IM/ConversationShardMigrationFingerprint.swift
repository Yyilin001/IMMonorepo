import Crypto
import Fluent
import Foundation

/// Stable canonical fingerprint shared by local and remote migration
/// verification. Auxiliary recipient snapshots are included with their fully
/// resolved recipient list, so a target cannot pass verification with the
/// correct row count but different delivery semantics.
enum ConversationShardMigrationFingerprint {
    static func compute(
        conversationID: UUID,
        database: any Database,
        pageSize: Int
    ) async throws -> String {
        var hasher = SHA256()
        func append(_ label: String, _ fields: [String?]) {
            let line = ([label] + fields.map { value in
                guard let value else { return "-1:" }
                return "\(value.utf8.count):\(value)"
            }).joined(separator: "|") + "\n"
            hasher.update(data: Data(line.utf8))
        }

        if let conversation = try await Conversation.find(conversationID, on: database) {
            append("conversation", conversation.migrationFingerprintFields)
        }
        try await appendPages(
            pageSize: pageSize,
            fetch: { offset, limit in
                try await ConversationMember.query(on: database)
                    .filter(\.$conversation.$id == conversationID)
                    .sort(\.$id, .ascending)
                    .range(offset..<(offset + limit)).all()
            },
            append: { append("member", $0.migrationFingerprintFields) }
        )
        try await appendPages(
            pageSize: pageSize,
            fetch: { offset, limit in
                try await ConversationMessage.query(on: database)
                    .filter(\.$conversation.$id == conversationID)
                    .sort(\.$timelineSequence, .ascending).sort(\.$id, .ascending)
                    .range(offset..<(offset + limit)).all()
            },
            append: { append("message", $0.migrationFingerprintFields) }
        )
        try await appendPages(
            pageSize: pageSize,
            fetch: { offset, limit in
                try await ConversationDomainEvent.query(on: database)
                    .filter(\.$conversationID == conversationID)
                    .sort(\.$aggregateSequence, .ascending).sort(\.$id, .ascending)
                    .range(offset..<(offset + limit)).all()
            },
            append: { append("event", $0.migrationFingerprintFields) }
        )
        if let sequence = try await ConversationDomainEventSequence.find(conversationID, on: database) {
            append("event_sequence", sequence.migrationFingerprintFields)
        }
        try await appendPages(
            pageSize: pageSize,
            fetch: { offset, limit in
                try await ConversationTimelineNotice.query(on: database)
                    .filter(\.$conversationID == conversationID)
                    .sort(\.$timelineSequence, .ascending).sort(\.$id, .ascending)
                    .range(offset..<(offset + limit)).all()
            },
            append: { append("notice", $0.migrationFingerprintFields) }
        )
        try await appendPages(
            pageSize: pageSize,
            fetch: { offset, limit in
                try await ConversationMediaAssetReference.query(on: database)
                    .filter(\.$conversationID == conversationID)
                    .sort(\.$serverSequence, .ascending).sort(\.$id, .ascending)
                    .range(offset..<(offset + limit)).all()
            },
            append: { append("media", $0.migrationFingerprintFields) }
        )

        var recipientOffset = 0
        while true {
            let snapshots = try await ConversationDomainEventRecipientSnapshot.query(on: database)
                .filter(\.$conversationID == conversationID)
                .sort(\.$id, .ascending)
                .range(recipientOffset..<(recipientOffset + pageSize)).all()
            guard !snapshots.isEmpty else { break }
            for snapshot in snapshots {
                let recipients = try await snapshot.recipientUserIDs(on: database)
                    .map { $0.uuidString.lowercased() }
                    .joined(separator: ",")
                append("recipient_snapshot", [
                    snapshot.id?.uuidString,
                    snapshot.conversationID.uuidString,
                    recipients,
                    String(snapshot.recipientCount),
                    snapshot.recipientHash,
                    String(snapshot.createdAt.timeIntervalSince1970)
                ])
            }
            recipientOffset += snapshots.count
        }
        return Data(hasher.finalize()).map { String(format: "%02x", $0) }.joined()
    }

    private static func appendPages<Record>(
        pageSize: Int,
        fetch: (Int, Int) async throws -> [Record],
        append: (Record) -> Void
    ) async throws {
        var offset = 0
        while true {
            let records = try await fetch(offset, pageSize)
            guard !records.isEmpty else { return }
            records.forEach(append)
            offset += records.count
        }
    }
}
