import Fluent
import SQLKit
import Vapor

struct ConversationMediaAssetReferenceDirectoryService {
    let db: any Database

    func sync(
        referencesByMessageID: [UUID: ConversationMediaAssetReference?],
        shardID: String,
        on database: (any Database)? = nil
    ) async throws {
        let database = database ?? db
        guard !referencesByMessageID.isEmpty else {
            return
        }

        let recordIDs = referencesByMessageID.keys.map(ConversationMediaAssetReferenceDirectory.recordID)
        let existingEntries = try await ConversationMediaAssetReferenceDirectory.query(on: database)
            .filter(\.$id ~~ recordIDs)
            .all()
        let existingEntriesByID = Dictionary(uniqueKeysWithValues: existingEntries.compactMap { entry in
            entry.id.map { ($0, entry) }
        })

        var entriesToUpsert: [ConversationMediaAssetReferenceDirectory] = []
        var recordIDsToDelete: [String] = []
        for (messageID, reference) in referencesByMessageID {
            let recordID = ConversationMediaAssetReferenceDirectory.recordID(messageID: messageID)
            guard let reference else {
                if existingEntriesByID[recordID] != nil {
                    recordIDsToDelete.append(recordID)
                }
                continue
            }

            let now = Date()
            let directoryEntry = existingEntriesByID[recordID] ?? ConversationMediaAssetReferenceDirectory(
                    messageID: reference.messageID,
                    assetID: reference.assetID,
                    shardID: shardID,
                    ownerUserID: reference.ownerUserID,
                    conversationID: reference.conversationID,
                    serverSequence: reference.serverSequence,
                    kind: reference.kind,
                    createdAt: reference.createdAt,
                    updatedAt: now
                )
            directoryEntry.assetID = reference.assetID
            directoryEntry.shardID = shardID
            directoryEntry.ownerUserID = reference.ownerUserID
            directoryEntry.conversationID = reference.conversationID
            directoryEntry.messageID = reference.messageID
            directoryEntry.serverSequence = reference.serverSequence
            directoryEntry.kind = reference.kind
            directoryEntry.updatedAt = now
            entriesToUpsert.append(directoryEntry)
        }
        try await delete(recordIDs: recordIDsToDelete, on: database)
        try await upsert(entriesToUpsert, on: database)
    }

    func sync(
        reference: ConversationMediaAssetReference?,
        shardID: String,
        messageID: UUID,
        on database: (any Database)? = nil
    ) async throws {
        let database = database ?? db
        let recordID = ConversationMediaAssetReferenceDirectory.recordID(messageID: messageID)
        guard let reference else {
            try await delete(recordID: recordID, on: database)
            return
        }

        let now = Date()
        if let existing = try await ConversationMediaAssetReferenceDirectory.find(recordID, on: database) {
            existing.assetID = reference.assetID
            existing.shardID = shardID
            existing.ownerUserID = reference.ownerUserID
            existing.conversationID = reference.conversationID
            existing.messageID = reference.messageID
            existing.serverSequence = reference.serverSequence
            existing.kind = reference.kind
            existing.updatedAt = now
            try await existing.update(on: database)
            return
        }

        let directoryEntry = ConversationMediaAssetReferenceDirectory(
            messageID: reference.messageID,
            assetID: reference.assetID,
            shardID: shardID,
            ownerUserID: reference.ownerUserID,
            conversationID: reference.conversationID,
            serverSequence: reference.serverSequence,
            kind: reference.kind,
            createdAt: reference.createdAt,
            updatedAt: now
        )
        try await directoryEntry.create(on: database)
    }

    func references(
        assetID: String,
        on database: (any Database)? = nil
    ) async throws -> [ConversationMediaAssetReferenceDirectory] {
        try await ConversationMediaAssetReferenceDirectory.query(on: database ?? db)
            .filter(\.$assetID == assetID)
            .sort(\.$serverSequence, .descending)
            .all()
    }

    private func delete(recordID: String, on database: any Database) async throws {
        guard let existing = try await ConversationMediaAssetReferenceDirectory.find(recordID, on: database) else {
            return
        }
        try await existing.delete(on: database)
    }

    private func delete(recordIDs: [String], on database: any Database) async throws {
        guard !recordIDs.isEmpty else {
            return
        }
        try await ConversationMediaAssetReferenceDirectory.query(on: database)
            .filter(\.$id ~~ recordIDs)
            .delete()
    }

    private func upsert(_ entries: [ConversationMediaAssetReferenceDirectory], on database: any Database) async throws {
        guard !entries.isEmpty else {
            return
        }

        guard let sql = database as? any SQLDatabase else {
            for entry in entries {
                if try await ConversationMediaAssetReferenceDirectory.find(entry.id, on: database) == nil {
                    try await entry.create(on: database)
                } else {
                    try await entry.update(on: database)
                }
            }
            return
        }

        let values = entries.map { entry in
            """
            (
                \(bind: entry.id),
                \(bind: entry.assetID),
                \(bind: entry.shardID),
                \(bind: entry.ownerUserID),
                \(bind: entry.conversationID),
                \(bind: entry.messageID),
                \(bind: entry.serverSequence),
                \(bind: entry.kind),
                \(bind: entry.createdAt),
                \(bind: entry.updatedAt)
            )
            """ as SQLQueryString
        }.joined(separator: ", ")

        try await sql.raw("""
            INSERT INTO \(ident: ConversationMediaAssetReferenceDirectory.schema) (
                \(ident: "id"),
                \(ident: "asset_id"),
                \(ident: "shard_id"),
                \(ident: "owner_user_id"),
                \(ident: "conversation_id"),
                \(ident: "message_id"),
                \(ident: "server_sequence"),
                \(ident: "kind"),
                \(ident: "created_at"),
                \(ident: "updated_at")
            )
            VALUES \(values)
            ON CONFLICT (\(ident: "id")) DO UPDATE SET
                \(ident: "asset_id") = \(ident: "excluded").\(ident: "asset_id"),
                \(ident: "shard_id") = \(ident: "excluded").\(ident: "shard_id"),
                \(ident: "owner_user_id") = \(ident: "excluded").\(ident: "owner_user_id"),
                \(ident: "conversation_id") = \(ident: "excluded").\(ident: "conversation_id"),
                \(ident: "message_id") = \(ident: "excluded").\(ident: "message_id"),
                \(ident: "server_sequence") = \(ident: "excluded").\(ident: "server_sequence"),
                \(ident: "kind") = \(ident: "excluded").\(ident: "kind"),
                \(ident: "updated_at") = \(ident: "excluded").\(ident: "updated_at")
            """).run()
    }
}
