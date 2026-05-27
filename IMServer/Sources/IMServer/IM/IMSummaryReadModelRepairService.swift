import Fluent
import Foundation
import Vapor

struct IMSummaryReadModelRepairService {
    private struct RoutedMembership: Sendable {
        let shardID: String
        let membership: ConversationMember
    }

    let app: Application

    func rebuildAllSummaries() async throws -> Int {
        let ownerUserIDs = try await allOwnerUserIDs()
        for ownerUserID in ownerUserIDs {
            try await rebuildSummaries(for: ownerUserID)
        }
        return ownerUserIDs.count
    }

    func rebuildSummaries(for ownerUserID: UUID) async throws {
        let memberships = try await routedMemberships(for: ownerUserID)
        let activeConversationIDs = Set(memberships.map { $0.membership.$conversation.id })

        for routedMembership in memberships {
            let conversationID = routedMembership.membership.$conversation.id
            let sourceDB = app.conversationShardRouter.commandDatabase(forShardID: routedMembership.shardID)
            for readModelDB in projectionReadModelDatabases(for: ownerUserID) {
                try await IMConversationSummaryProjectionService(
                    sourceDB: sourceDB,
                    readModelDB: readModelDB
                ).refreshConversationSummaries(
                    conversationID: conversationID,
                    recipientUserIDs: [ownerUserID],
                    on: sourceDB,
                    writeChangeLog: true
                )
            }
        }

        for readModelDB in projectionReadModelDatabases(for: ownerUserID) {
            let existingSummaries = try await ConversationUserSummary.query(on: readModelDB)
                .filter(\.$ownerUserID == ownerUserID)
                .all()
            for summary in existingSummaries where !activeConversationIDs.contains(summary.conversationID) && !summary.isRemoved {
                try await IMConversationSummaryProjectionService(
                    sourceDB: app.imWriteDB,
                    readModelDB: readModelDB
                ).markConversationRemoved(
                    conversationID: summary.conversationID,
                    recipientUserID: ownerUserID,
                    writeChangeLog: true
                )
            }
        }
    }

    func verifyAllSummaries() async throws -> ConversationSummaryVerificationResult {
        let ownerUserIDs = try await allOwnerUserIDs()
        var result = ConversationSummaryVerificationResult()
        for ownerUserID in ownerUserIDs {
            let ownerResult = try await verifySummaries(for: ownerUserID)
            result.accumulate(ownerResult)
        }
        return result
    }

    func verifySummaries(for ownerUserID: UUID) async throws -> ConversationSummaryVerificationResult {
        let memberships = try await routedMemberships(for: ownerUserID)
        let summaries = try await ConversationUserSummary.query(on: queryReadModelDatabase(for: ownerUserID))
            .filter(\.$ownerUserID == ownerUserID)
            .all()

        let activeMembershipsByConversationID = Dictionary(
            uniqueKeysWithValues: memberships.map { ($0.membership.$conversation.id, $0) }
        )
        let summariesByConversationID = Dictionary(
            uniqueKeysWithValues: summaries.map { ($0.conversationID, $0) }
        )

        var result = ConversationSummaryVerificationResult(ownerUserCount: 1)
        result.tombstoneSummaryCount = summaries.filter(\.isRemoved).count

        for routedMembership in memberships {
            let membership = routedMembership.membership
            let conversationID = membership.$conversation.id
            guard let summary = summariesByConversationID[conversationID],
                  !summary.isRemoved else {
                result.missingSummaryCount += 1
                continue
            }

            let sourceDB = app.conversationShardRouter.commandDatabase(forShardID: routedMembership.shardID)
            let lastVisibleMessage = try await ConversationMessage.query(on: sourceDB)
                .filter(\.$conversation.$id == conversationID)
                .filter(\.$serverSequence >= membership.visibleFromSequence)
                .sort(\.$serverSequence, .descending)
                .first()
            let expectedLastVisibleMessage = try lastVisibleMessage.map {
                try ConversationMessageService(db: sourceDB).makePreview(from: $0)
            }

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

        for summary in summaries where activeMembershipsByConversationID[summary.conversationID] == nil && !summary.isRemoved {
            result.staleActiveSummaryCount += 1
        }

        return result
    }

    private func routedMemberships(for ownerUserID: UUID) async throws -> [RoutedMembership] {
        var routedMemberships: [RoutedMembership] = []
        for shard in app.conversationShardRouter.allCommandDatabases() {
            let memberships = try await ConversationMember.query(on: shard.database)
                .filter(\.$user.$id == ownerUserID)
                .all()
            routedMemberships.append(
                contentsOf: memberships.map { RoutedMembership(shardID: shard.shardID, membership: $0) }
            )
        }
        return routedMemberships.sorted { lhs, rhs in
            lhs.membership.$conversation.id.uuidString < rhs.membership.$conversation.id.uuidString
        }
    }

    private func allOwnerUserIDs() async throws -> [UUID] {
        var membershipOwnerUserIDs: [UUID] = []
        for shard in app.conversationShardRouter.allCommandDatabases() {
            membershipOwnerUserIDs.append(
                contentsOf: try await ConversationMember.query(on: shard.database)
                    .all()
                    .map(\.$user.id)
            )
        }

        var shardedSummaryOwnerUserIDs: [UUID] = []
        for shardID in app.summaryShardRouter.shardIDs {
            let database = app.summaryShardRouter.database(forShardID: shardID)
            shardedSummaryOwnerUserIDs.append(
                contentsOf: try await ConversationUserSummary.query(on: database)
                    .all()
                    .map(\.ownerUserID)
            )
        }

        return Array(Set(membershipOwnerUserIDs + shardedSummaryOwnerUserIDs))
            .sorted { $0.uuidString < $1.uuidString }
    }

    private func projectionReadModelDatabases(for ownerUserID: UUID) -> [any Database] {
        [app.summaryShardRouter.database(forOwnerUserID: ownerUserID)]
    }

    private func queryReadModelDatabase(for ownerUserID: UUID) -> any Database {
        app.summaryShardRouter.database(forOwnerUserID: ownerUserID)
    }
}
