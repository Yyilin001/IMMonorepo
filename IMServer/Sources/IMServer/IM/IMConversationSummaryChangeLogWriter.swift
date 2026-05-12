import Fluent
import Foundation
import SQLKit
import Vapor

extension IMConversationSummaryProjectionService {
    func recordConversationSummaryChanges(
        conversationID: UUID,
        recipientUserIDs: [UUID]
    ) async throws {
        let uniqueUserIDs = Array(Set(recipientUserIDs)).sorted { $0.uuidString < $1.uuidString }
        guard !uniqueUserIDs.isEmpty else {
            return
        }

        let summaryRecordIDs = uniqueUserIDs.map {
            ConversationUserSummary.recordID(ownerUserID: $0, conversationID: conversationID)
        }
        let summaries = try await ConversationUserSummary.query(on: readModelDB)
            .filter(\.$id ~~ summaryRecordIDs)
            .all()
        let rows = summaries.compactMap { summary -> ConversationChangeLogBatchWriter.Row? in
            guard let summaryRecordID = summary.id else {
                return nil
            }
            return ConversationChangeLogBatchWriter.Row(
                ownerUserID: summary.ownerUserID,
                conversationID: conversationID,
                summaryRecordID: summaryRecordID,
                updatedAt: summary.updatedAt,
                isRemoved: summary.isRemoved
            )
        }
        try await ConversationChangeLogBatchWriter(database: readModelDB).upsert(rows)
    }

    func recordConversationRemovedChange(
        conversationID: UUID,
        recipientUserID: UUID
    ) async throws {
        let summaryRecordID = ConversationUserSummary.recordID(
            ownerUserID: recipientUserID,
            conversationID: conversationID
        )
        guard let summary = try await ConversationUserSummary.find(summaryRecordID, on: readModelDB) else {
            return
        }
        try await upsertChangeLog(
            ownerUserID: recipientUserID,
            conversationID: conversationID,
            summaryRecordID: summaryRecordID,
            updatedAt: summary.updatedAt,
            isRemoved: true,
            on: readModelDB
        )
    }
}

struct ConversationChangeLogBatchWriter {
    struct Row: Sendable {
        let ownerUserID: UUID
        let conversationID: UUID
        let summaryRecordID: String
        let updatedAt: Date
        let isRemoved: Bool

        var recordID: String {
            ConversationChangesLogEntry.recordID(ownerUserID: ownerUserID, conversationID: conversationID)
        }

        var tokenRecordID: String {
            ConversationReadModelToken.recordID(ownerUserID: ownerUserID)
        }

        var targetToken: String {
            IMConversationSummaryProjectionService.encodeChangeToken(
                IMConversationSummaryProjectionService.ChangeToken(updatedAt: updatedAt, recordID: recordID)
            )
        }
    }

    let database: any Database

    func upsert(_ rows: [Row]) async throws {
        guard !rows.isEmpty else {
            return
        }

        guard let sql = database as? any SQLDatabase else {
            let service = IMConversationSummaryProjectionService(db: database)
            for row in rows {
                try await service.upsertChangeLog(
                    ownerUserID: row.ownerUserID,
                    conversationID: row.conversationID,
                    summaryRecordID: row.summaryRecordID,
                    updatedAt: row.updatedAt,
                    isRemoved: row.isRemoved,
                    on: database
                )
            }
            return
        }

        let changeValues = rows.map { row in
            """
            (
                \(bind: row.recordID),
                \(bind: row.ownerUserID),
                \(bind: row.conversationID),
                \(bind: row.summaryRecordID),
                \(bind: row.updatedAt),
                \(bind: row.isRemoved)
            )
            """ as SQLQueryString
        }.joined(separator: ", ")
        try await sql.raw("""
            INSERT INTO \(ident: ConversationChangesLogEntry.schema) (
                \(ident: "id"),
                \(ident: "owner_user_id"),
                \(ident: "conversation_id"),
                \(ident: "summary_record_id"),
                \(ident: "updated_at"),
                \(ident: "is_removed")
            )
            VALUES \(changeValues)
            ON CONFLICT (\(ident: "id")) DO UPDATE SET
                \(ident: "owner_user_id") = \(ident: "excluded").\(ident: "owner_user_id"),
                \(ident: "conversation_id") = \(ident: "excluded").\(ident: "conversation_id"),
                \(ident: "summary_record_id") = \(ident: "excluded").\(ident: "summary_record_id"),
                \(ident: "updated_at") = \(ident: "excluded").\(ident: "updated_at"),
                \(ident: "is_removed") = \(ident: "excluded").\(ident: "is_removed")
            """).run()

        let tokenValues = rows.map { row in
            """
            (
                \(bind: row.tokenRecordID),
                \(bind: row.ownerUserID),
                \(bind: row.targetToken),
                \(bind: row.updatedAt)
            )
            """ as SQLQueryString
        }.joined(separator: ", ")
        try await sql.raw("""
            INSERT INTO \(ident: ConversationReadModelToken.schema) (
                \(ident: "id"),
                \(ident: "owner_user_id"),
                \(ident: "target_token"),
                \(ident: "updated_at")
            )
            VALUES \(tokenValues)
            ON CONFLICT (\(ident: "id")) DO UPDATE SET
                \(ident: "owner_user_id") = \(ident: "excluded").\(ident: "owner_user_id"),
                \(ident: "target_token") = \(ident: "excluded").\(ident: "target_token"),
                \(ident: "updated_at") = \(ident: "excluded").\(ident: "updated_at")
            """).run()
    }
}
