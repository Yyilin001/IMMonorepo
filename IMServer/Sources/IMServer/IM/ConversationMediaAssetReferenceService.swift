import Fluent
import SQLKit
import Vapor

struct ConversationMediaAssetReferenceService {
    let db: any Database

    func syncMessageReferences(
        conversationID: UUID,
        messageIDs: [UUID],
        on database: (any Database)? = nil
    ) async throws -> [UUID: ConversationMediaAssetReference?] {
        let database = database ?? db
        let uniqueMessageIDs = Array(Set(messageIDs))
        guard !uniqueMessageIDs.isEmpty else {
            return [:]
        }

        let messages = try await ConversationMessage.query(on: database)
            .filter(\.$conversation.$id == conversationID)
            .filter(\.$id ~~ uniqueMessageIDs)
            .all()
        let messagesByID = Dictionary(uniqueKeysWithValues: messages.compactMap { message in
            message.id.map { ($0, message) }
        })
        let recordIDs = uniqueMessageIDs.map(ConversationMediaAssetReference.recordID)
        let existingReferences = try await ConversationMediaAssetReference.query(on: database)
            .filter(\.$id ~~ recordIDs)
            .all()
        let existingReferencesByID = Dictionary(uniqueKeysWithValues: existingReferences.compactMap { reference in
            reference.id.map { ($0, reference) }
        })

        var results: [UUID: ConversationMediaAssetReference?] = [:]
        results.reserveCapacity(uniqueMessageIDs.count)
        var referencesToUpsert: [ConversationMediaAssetReference] = []
        var recordIDsToDelete: [String] = []
        for messageID in uniqueMessageIDs {
            let recordID = ConversationMediaAssetReference.recordID(messageID: messageID)
            guard let message = messagesByID[messageID],
                  let asset = try message.decodedContent().mediaAsset
            else {
                if existingReferencesByID[recordID] != nil {
                    recordIDsToDelete.append(recordID)
                }
                results[messageID] = nil
                continue
            }

            let now = Date()
            let reference = existingReferencesByID[recordID] ?? ConversationMediaAssetReference(
                    messageID: messageID,
                    assetID: asset.assetID,
                    ownerUserID: message.$sender.id,
                    conversationID: conversationID,
                    serverSequence: message.serverSequence,
                    kind: asset.kind.rawValue,
                    createdAt: message.createdAt ?? now,
                    updatedAt: now
                )
            reference.assetID = asset.assetID
            reference.ownerUserID = message.$sender.id
            reference.conversationID = conversationID
            reference.messageID = messageID
            reference.serverSequence = message.serverSequence
            reference.kind = asset.kind.rawValue
            reference.updatedAt = now
            referencesToUpsert.append(reference)
            results[messageID] = reference
        }
        try await deleteReferences(recordIDs: recordIDsToDelete, on: database)
        try await upsertReferences(referencesToUpsert, on: database)
        return results
    }

    func syncMessageReference(
        conversationID: UUID,
        messageID: UUID,
        on database: (any Database)? = nil
    ) async throws -> ConversationMediaAssetReference? {
        let database = database ?? db
        let recordID = ConversationMediaAssetReference.recordID(messageID: messageID)
        guard let message = try await ConversationMessage.query(on: database)
            .filter(\.$id == messageID)
            .filter(\.$conversation.$id == conversationID)
            .first()
        else {
            try await deleteReference(recordID: recordID, on: database)
            return nil
        }

        guard let asset = try message.decodedContent().mediaAsset else {
            try await deleteReference(recordID: recordID, on: database)
            return nil
        }

        let now = Date()
        if let existing = try await ConversationMediaAssetReference.find(recordID, on: database) {
            existing.assetID = asset.assetID
            existing.ownerUserID = message.$sender.id
            existing.conversationID = conversationID
            existing.messageID = messageID
            existing.serverSequence = message.serverSequence
            existing.kind = asset.kind.rawValue
            existing.updatedAt = now
            try await existing.update(on: database)
            return existing
        }

        let reference = ConversationMediaAssetReference(
            messageID: messageID,
            assetID: asset.assetID,
            ownerUserID: message.$sender.id,
            conversationID: conversationID,
            serverSequence: message.serverSequence,
            kind: asset.kind.rawValue,
            createdAt: message.createdAt ?? now,
            updatedAt: now
        )
        try await reference.create(on: database)
        return reference
    }

    func references(assetID: String, on database: (any Database)? = nil) async throws -> [ConversationMediaAssetReference] {
        try await ConversationMediaAssetReference.query(on: database ?? db)
            .filter(\.$assetID == assetID)
            .sort(\.$serverSequence, .descending)
            .all()
    }

    private func deleteReference(recordID: String, on database: any Database) async throws {
        guard let existing = try await ConversationMediaAssetReference.find(recordID, on: database) else {
            return
        }
        try await existing.delete(on: database)
    }

    private func deleteReferences(recordIDs: [String], on database: any Database) async throws {
        guard !recordIDs.isEmpty else {
            return
        }
        try await ConversationMediaAssetReference.query(on: database)
            .filter(\.$id ~~ recordIDs)
            .delete()
    }

    private func upsertReferences(_ references: [ConversationMediaAssetReference], on database: any Database) async throws {
        guard !references.isEmpty else {
            return
        }

        guard let sql = database as? any SQLDatabase else {
            for reference in references {
                if try await ConversationMediaAssetReference.find(reference.id, on: database) == nil {
                    try await reference.create(on: database)
                } else {
                    try await reference.update(on: database)
                }
            }
            return
        }

        let values = references.map { reference in
            """
            (
                \(bind: reference.id),
                \(bind: reference.assetID),
                \(bind: reference.ownerUserID),
                \(bind: reference.conversationID),
                \(bind: reference.messageID),
                \(bind: reference.serverSequence),
                \(bind: reference.kind),
                \(bind: reference.createdAt),
                \(bind: reference.updatedAt)
            )
            """ as SQLQueryString
        }.joined(separator: ", ")

        try await sql.raw("""
            INSERT INTO \(ident: ConversationMediaAssetReference.schema) (
                \(ident: "id"),
                \(ident: "asset_id"),
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
                \(ident: "owner_user_id") = \(ident: "excluded").\(ident: "owner_user_id"),
                \(ident: "conversation_id") = \(ident: "excluded").\(ident: "conversation_id"),
                \(ident: "message_id") = \(ident: "excluded").\(ident: "message_id"),
                \(ident: "server_sequence") = \(ident: "excluded").\(ident: "server_sequence"),
                \(ident: "kind") = \(ident: "excluded").\(ident: "kind"),
                \(ident: "updated_at") = \(ident: "excluded").\(ident: "updated_at")
            """).run()
    }
}
