import Fluent
import Foundation
import SQLKit
import Vapor

extension IMConversationSummaryProjectionService {
    private static let defaultOpsOwnerBatchSize = 500

    func rebuildSummaries(for userID: UUID, batchSize: Int = Self.defaultOpsOwnerBatchSize) async throws {
        var activeConversationIDs: [UUID] = []
        try await forEachMembershipPage(
            ownerUserID: userID,
            batchSize: batchSize
        ) { memberships in
            for conversationID in memberships.map(\.$conversation.id) {
                activeConversationIDs.append(conversationID)
                try await refreshConversationSummaries(
                    conversationID: conversationID,
                    recipientUserIDs: [userID],
                    on: sourceDB,
                    writeChangeLog: true
                )
            }
        }

        let existing = try await ConversationUserSummary.query(on: readModelDB)
            .filter(\.$ownerUserID == userID)
            .all()
        let activeSet = Set(activeConversationIDs)
        for summary in existing where !activeSet.contains(summary.conversationID) && !summary.isRemoved {
            summary.isRemoved = true
            summary.updatedAt = Date()
            try await save(summary, on: readModelDB)
            try await upsertChangeLog(
                ownerUserID: userID,
                conversationID: summary.conversationID,
                summaryRecordID: summary.id ?? ConversationUserSummary.recordID(ownerUserID: userID, conversationID: summary.conversationID),
                updatedAt: summary.updatedAt,
                isRemoved: true,
                on: readModelDB
            )
        }
    }

    func rebuildAllSummaries(batchSize: Int = Self.defaultOpsOwnerBatchSize) async throws -> Int {
        var rebuiltOwnerIDs: Set<UUID> = []
        try await forEachSummaryOwnerID(batchSize: batchSize) { ownerUserID in
            guard !rebuiltOwnerIDs.contains(ownerUserID) else {
                return
            }
            rebuiltOwnerIDs.insert(ownerUserID)
            try await self.rebuildSummaries(for: ownerUserID, batchSize: batchSize)
        }
        return rebuiltOwnerIDs.count
    }

    func verifySummaries(for userID: UUID, batchSize: Int = Self.defaultOpsOwnerBatchSize) async throws -> ConversationSummaryVerificationResult {
        let summaries = try await ConversationUserSummary.query(on: readModelDB)
            .filter(\.$ownerUserID == userID)
            .all()

        let summariesByConversationID = Dictionary(
            uniqueKeysWithValues: summaries.map { ($0.conversationID, $0) }
        )

        var result = ConversationSummaryVerificationResult(ownerUserCount: 1)
        result.tombstoneSummaryCount = summaries.filter(\.isRemoved).count
        var activeConversationIDs: Set<UUID> = []

        try await forEachMembershipPage(
            ownerUserID: userID,
            batchSize: batchSize
        ) { memberships in
            let latestMessagesByConversationID = try await latestVisibleMessagesByConversationID(
                memberships: memberships,
                on: sourceDB
            )

            for membership in memberships {
                let conversationID = membership.$conversation.id
                activeConversationIDs.insert(conversationID)
                guard let summary = summariesByConversationID[conversationID],
                      !summary.isRemoved
                else {
                    result.missingSummaryCount += 1
                    continue
                }

                let lastVisibleMessage = latestMessagesByConversationID[conversationID] ?? nil
                let expectedLastVisibleMessage = try lastVisibleMessage.map(makePreview)

                if summary.lastMessage != expectedLastVisibleMessage {
                    result.latestVisibleMessageMismatchCount += 1
                }

                let latestVisibleSequence = max(
                    lastVisibleMessage?.serverSequence ?? 0,
                    max(0, membership.visibleFromSequence - 1)
                )
                let effectiveLastReadSequence = max(
                    membership.lastReadSequence,
                    max(0, membership.visibleFromSequence - 1)
                )
                let expectedUnreadCount = max(0, latestVisibleSequence - effectiveLastReadSequence)
                if summary.lastReadSequence != effectiveLastReadSequence
                    || summary.unreadCount != expectedUnreadCount {
                    result.unreadMismatchCount += 1
                }
            }
        }

        for summary in summaries where !activeConversationIDs.contains(summary.conversationID) && !summary.isRemoved {
            result.staleActiveSummaryCount += 1
        }

        return result
    }

    func verifyAllSummaries(batchSize: Int = Self.defaultOpsOwnerBatchSize) async throws -> ConversationSummaryVerificationResult {
        var result = ConversationSummaryVerificationResult()
        var verifiedOwnerIDs: Set<UUID> = []
        try await forEachSummaryOwnerID(batchSize: batchSize) { ownerUserID in
            guard !verifiedOwnerIDs.contains(ownerUserID) else {
                return
            }
            verifiedOwnerIDs.insert(ownerUserID)
            let ownerResult = try await verifySummaries(for: ownerUserID, batchSize: batchSize)
            result.accumulate(ownerResult)
        }
        return result
    }

    private func forEachMembershipPage(
        ownerUserID: UUID,
        batchSize: Int,
        _ body: ([ConversationMember]) async throws -> Void
    ) async throws {
        let normalizedBatchSize = max(1, batchSize)
        guard let sql = sourceDB as? any SQLDatabase,
              sql.dialect.name == "postgresql" || sql.dialect.name == "sqlite"
        else {
            let memberships = try await ConversationMember.query(on: sourceDB)
                .filter(\.$user.$id == ownerUserID)
                .all()
            try await body(memberships)
            return
        }

        struct MembershipIDRow: Decodable {
            let id: UUID
        }

        var lastID: UUID?
        while true {
            let rows: [MembershipIDRow]
            if let lastID {
                rows = try await sql.raw("""
                    SELECT \(ident: "id")
                    FROM \(ident: ConversationMember.schema)
                    WHERE \(ident: "user_id") = \(bind: ownerUserID)
                      AND \(ident: "id") > \(bind: lastID)
                    ORDER BY \(ident: "id") ASC
                    LIMIT \(bind: normalizedBatchSize)
                    """).all(decoding: MembershipIDRow.self)
            } else {
                rows = try await sql.raw("""
                    SELECT \(ident: "id")
                    FROM \(ident: ConversationMember.schema)
                    WHERE \(ident: "user_id") = \(bind: ownerUserID)
                    ORDER BY \(ident: "id") ASC
                    LIMIT \(bind: normalizedBatchSize)
                    """).all(decoding: MembershipIDRow.self)
            }
            guard !rows.isEmpty else {
                return
            }

            let ids = rows.map(\.id)
            let memberships = try await ConversationMember.query(on: sourceDB)
                .filter(\.$id ~~ ids)
                .all()
                .sorted { ($0.id?.uuidString ?? "") < ($1.id?.uuidString ?? "") }
            try await body(memberships)
            lastID = rows.last?.id
            if rows.count < normalizedBatchSize {
                return
            }
        }
    }

    private func forEachSummaryOwnerID(
        batchSize: Int,
        _ body: (UUID) async throws -> Void
    ) async throws {
        let normalizedBatchSize = max(1, batchSize)
        if let sourceSQL = sourceDB as? any SQLDatabase,
           let readModelSQL = readModelDB as? any SQLDatabase {
            try await forEachOwnerID(
                sql: sourceSQL,
                table: ConversationMember.schema,
                column: "user_id",
                batchSize: normalizedBatchSize,
                body
            )
            try await forEachOwnerID(
                sql: readModelSQL,
                table: ConversationUserSummary.schema,
                column: "owner_user_id",
                batchSize: normalizedBatchSize,
                body
            )
            return
        }

        let membershipOwnerUserIDs = try await ConversationMember.query(on: sourceDB)
            .all()
            .map(\.$user.id)
        let summaryOwnerUserIDs = try await ConversationUserSummary.query(on: readModelDB)
            .all()
            .map(\.ownerUserID)
        let ownerUserIDs = Array(Set(membershipOwnerUserIDs + summaryOwnerUserIDs))
            .sorted { $0.uuidString < $1.uuidString }
        for ownerUserID in ownerUserIDs {
            try await body(ownerUserID)
        }
    }

    private func forEachOwnerID(
        sql: any SQLDatabase,
        table: String,
        column: String,
        batchSize: Int,
        _ body: (UUID) async throws -> Void
    ) async throws {
        struct OwnerIDRow: Decodable {
            let ownerUserID: UUID

            enum CodingKeys: String, CodingKey {
                case ownerUserID = "owner_user_id"
            }
        }

        var offset = 0
        while true {
            let rows = try await sql.raw("""
                SELECT DISTINCT \(ident: column) AS \(ident: "owner_user_id")
                FROM \(ident: table)
                ORDER BY \(ident: column) ASC
                LIMIT \(bind: batchSize)
                OFFSET \(bind: offset)
                """).all(decoding: OwnerIDRow.self)
            guard !rows.isEmpty else {
                return
            }
            for row in rows {
                try await body(row.ownerUserID)
            }
            offset += rows.count
            if rows.count < batchSize {
                return
            }
        }
    }

    private func latestVisibleMessagesByConversationID(
        memberships: [ConversationMember],
        on database: any Database
    ) async throws -> [UUID: ConversationMessage] {
        guard !memberships.isEmpty else {
            return [:]
        }

        guard let sql = database as? any SQLDatabase,
              sql.dialect.name == "postgresql" || sql.dialect.name == "sqlite"
        else {
            var result: [UUID: ConversationMessage] = [:]
            for membership in memberships {
                let conversationID = membership.$conversation.id
                if let lastVisibleMessage = try await ConversationMessage.query(on: database)
                    .filter(\.$conversation.$id == conversationID)
                    .filter(\.$serverSequence >= membership.visibleFromSequence)
                    .sort(\.$serverSequence, .descending)
                    .first()
                {
                    result[conversationID] = lastVisibleMessage
                }
            }
            return result
        }

        struct LatestMessageRow: Decodable {
            let conversationID: UUID
            let messageID: UUID?

            enum CodingKeys: String, CodingKey {
                case conversationID = "conversation_id"
                case messageID = "message_id"
            }
        }

        let values = memberships.map { membership in
            "(\(bind: membership.$conversation.id), \(bind: membership.visibleFromSequence))" as SQLQueryString
        }.joined(separator: ", ")
        let rows = try await sql.raw("""
            WITH \(ident: "membership_thresholds")(
                \(ident: "conversation_id"),
                \(ident: "visible_from_sequence")
            ) AS (
                VALUES \(values)
            )
            SELECT
                \(ident: "membership_thresholds").\(ident: "conversation_id"),
                (
                    SELECT \(ident: "message").\(ident: "id")
                    FROM \(ident: ConversationMessage.schema) AS \(ident: "message")
                    WHERE \(ident: "message").\(ident: "conversation_id") = \(ident: "membership_thresholds").\(ident: "conversation_id")
                      AND \(ident: "message").\(ident: "server_sequence") >= \(ident: "membership_thresholds").\(ident: "visible_from_sequence")
                    ORDER BY \(ident: "message").\(ident: "server_sequence") DESC
                    LIMIT 1
                ) AS \(ident: "message_id")
            FROM \(ident: "membership_thresholds")
            """).all(decoding: LatestMessageRow.self)

        let messageIDs = Array(Set(rows.compactMap(\.messageID)))
        guard !messageIDs.isEmpty else {
            return [:]
        }
        let messages = try await ConversationMessage.query(on: database)
            .filter(\.$id ~~ messageIDs)
            .all()
        let messagesByID = Dictionary(uniqueKeysWithValues: messages.compactMap { message in
            message.id.map { ($0, message) }
        })
        return Dictionary(uniqueKeysWithValues: rows.compactMap { row in
            guard let messageID = row.messageID,
                  let message = messagesByID[messageID]
            else {
                return nil
            }
            return (row.conversationID, message)
        })
    }
}
