import Fluent
import Foundation
import SQLKit
import Vapor

// Maintains per-user conversation summaries from canonical events. This is a
// read-model projection layer; command behavior belongs in conversation services.
extension IMConversationSummaryProjectionService {
    func applyMessageCreatedActivityOnly(
        conversationID: UUID,
        messageID: UUID,
        recipientCount: Int,
        on database: (any Database)? = nil,
        readModelKey: String = "default",
        recordMetrics: Bool = true
    ) async throws {
        let database = database ?? sourceDB
        guard recipientCount > 0 else {
            return
        }
        guard let message = try await ConversationMessage.find(messageID, on: database),
              message.$conversation.id == conversationID
        else {
            return
        }

        let messagePreview = try makePreview(from: message)
        let updatedAt = Date()
        if recordMetrics {
            await domainEventMetrics?.recordMessageCreatedSummaryActivityOnly(recipientCount: recipientCount)
        }
        if let activitySummaryCoalescer,
           streamConsumerConfiguration.summaryProjectionActivityCoalesceWindowMilliseconds > 0 {
            await activitySummaryCoalescer.enqueue(
                conversationID: conversationID,
                messageServerSequence: message.serverSequence,
                messagePreview: messagePreview,
                messageCreatedAt: message.createdAt,
                updatedAt: updatedAt,
                readModelDB: readModelDB,
                readModelKey: readModelKey,
                windowMilliseconds: streamConsumerConfiguration.summaryProjectionActivityCoalesceWindowMilliseconds
            )
            return
        }
        try await upsertConversationActivity(
            conversationID: conversationID,
            messageServerSequence: message.serverSequence,
            messagePreview: messagePreview,
            messageCreatedAt: message.createdAt,
            updatedAt: updatedAt,
            on: readModelDB
        )
    }

    func applyMessageCreated(
        conversationID: UUID,
        messageID: UUID,
        recipientUserIDs: [UUID],
        on database: (any Database)? = nil,
        writeChangeLog: Bool = true
    ) async throws {
        let database = database ?? sourceDB
        let readModelDatabase = readModelDB
        let uniqueUserIDs = Array(Set(recipientUserIDs)).sorted { $0.uuidString < $1.uuidString }
        guard !uniqueUserIDs.isEmpty else {
            return
        }

        guard let message = try await ConversationMessage.find(messageID, on: database),
              message.$conversation.id == conversationID
        else {
            return
        }

        let messagePreview = try makePreview(from: message)
        let updatedAt = Date()
        if shouldProjectMessageCreatedToActivityOnly(recipientCount: uniqueUserIDs.count) {
            try await applyMessageCreatedActivityOnly(
                conversationID: conversationID,
                messageID: messageID,
                recipientCount: uniqueUserIDs.count,
                on: database
            )
            return
        }
        let summaryRecordIDs = uniqueUserIDs.map {
            ConversationUserSummary.recordID(ownerUserID: $0, conversationID: conversationID)
        }
        let existingSummaries = try await ConversationUserSummary.query(on: readModelDatabase)
            .filter(\.$id ~~ summaryRecordIDs)
            .all()
        let existingSummariesByID = Dictionary(uniqueKeysWithValues: existingSummaries.compactMap { summary in
            summary.id.map { ($0, summary) }
        })
        let existingUserIDs = uniqueUserIDs.filter { recipientUserID in
            existingSummariesByID[
                ConversationUserSummary.recordID(ownerUserID: recipientUserID, conversationID: conversationID)
            ] != nil
        }
        let missingUserIDs = uniqueUserIDs.filter { recipientUserID in
            existingSummariesByID[
                ConversationUserSummary.recordID(ownerUserID: recipientUserID, conversationID: conversationID)
            ] == nil
        }

        if !missingUserIDs.isEmpty {
            try await refreshConversationSummaries(
                conversationID: conversationID,
                recipientUserIDs: missingUserIDs,
                on: database,
                writeChangeLog: writeChangeLog,
                preferredMessage: message
            )
        }

        guard !existingUserIDs.isEmpty else {
            return
        }

        let memberships = try await ConversationMember.query(on: database)
            .filter(\.$conversation.$id == conversationID)
            .filter(\.$user.$id ~~ existingUserIDs)
            .all()
        guard !memberships.isEmpty else {
            return
        }

        let membershipsByUserID = Dictionary(uniqueKeysWithValues: memberships.map { ($0.$user.id, $0) })
        var summariesToUpdate: [ConversationUserSummary] = []
        summariesToUpdate.reserveCapacity(existingUserIDs.count)
        var changeLogRows: [ConversationChangeLogBatchWriter.Row] = []
        changeLogRows.reserveCapacity(existingUserIDs.count)

        for recipientUserID in existingUserIDs {
            guard let membership = membershipsByUserID[recipientUserID],
                  message.serverSequence >= membership.visibleFromSequence
            else {
                continue
            }

            let recordID = ConversationUserSummary.recordID(ownerUserID: recipientUserID, conversationID: conversationID)
            guard let summary = existingSummariesByID[recordID] else {
                continue
            }

            let messageServerSequence = try imPositiveUInt64Sequence(message.serverSequence, field: "server_sequence")
            let currentLastSequence = summary.lastMessage?.serverSequence ?? 0
            if messageServerSequence >= currentLastSequence {
                summary.lastMessage = messagePreview
                summary.lastActivityAt = message.createdAt ?? updatedAt
            }

            let visibleLowerBound = max(0, membership.visibleFromSequence - 1)
            let effectiveLastReadSequence = max(
                membership.lastReadSequence,
                visibleLowerBound
            )
            let latestVisibleSequence = max(
                messageServerSequence,
                currentLastSequence,
                UInt64(visibleLowerBound)
            )
            summary.lastReadSequence = effectiveLastReadSequence
            let unreadCount = latestVisibleSequence > UInt64(effectiveLastReadSequence)
                ? latestVisibleSequence - UInt64(effectiveLastReadSequence)
                : 0
            summary.unreadCount = try imIntSequence(unreadCount, field: "unread_count")
            summary.updatedAt = updatedAt
            summary.isRemoved = false
            summariesToUpdate.append(summary)
            if writeChangeLog {
                changeLogRows.append(
                    ConversationChangeLogBatchWriter.Row(
                    ownerUserID: recipientUserID,
                    conversationID: conversationID,
                    summaryRecordID: summary.id ?? ConversationUserSummary.recordID(
                        ownerUserID: recipientUserID,
                        conversationID: conversationID
                    ),
                    updatedAt: updatedAt,
                        isRemoved: false
                    )
                )
            }
        }

        try await updateMessageCreatedDynamicSummaries(summariesToUpdate, on: readModelDatabase)
        try await ConversationChangeLogBatchWriter(database: readModelDatabase).upsert(changeLogRows)
    }

    private func shouldProjectMessageCreatedToActivityOnly(recipientCount: Int) -> Bool {
        let threshold = streamConsumerConfiguration.summaryProjectionMessageCreatedActivityOnlyRecipientThreshold
        return threshold > 0 && recipientCount >= threshold
    }

    func refreshConversationSummaries(
        conversationID: UUID,
        recipientUserIDs: [UUID],
        on database: (any Database)? = nil,
        writeChangeLog: Bool = true,
        preferredMessage: ConversationMessage? = nil
    ) async throws {
        let database = database ?? sourceDB
        let readModelDatabase = readModelDB
        let uniqueUserIDs = Array(Set(recipientUserIDs)).sorted { $0.uuidString < $1.uuidString }
        guard !uniqueUserIDs.isEmpty else {
            return
        }

        guard let conversation = try await Conversation.find(conversationID, on: database) else {
            return
        }

        let memberships = try await ConversationMember.query(on: database)
            .filter(\.$conversation.$id == conversationID)
            .all()
        guard !memberships.isEmpty else {
            return
        }

        let memberUserIDs = memberships.map(\.$user.id).sorted { $0.uuidString < $1.uuidString }
        let storedMemberUserIDs = memberUserIDsForSummaryStorage(
            memberUserIDs,
            conversationKind: conversation.conversationKind
        )
        let usersByID: [UUID: User]
        if conversation.conversationKind == .direct {
            usersByID = try await ConversationUserDirectory(db: userDirectoryDB).usersByID(memberUserIDs)
        } else {
            usersByID = [:]
        }
        let membershipsByUserID = Dictionary(uniqueKeysWithValues: memberships.map { ($0.$user.id, $0) })
        let latestMessageByVisibleFrom = try await latestVisibleMessagesByThreshold(
            conversationID: conversationID,
            memberships: memberships,
            preferredMessage: preferredMessage,
            on: database
        )
        let summaryRecordIDs = uniqueUserIDs.map {
            ConversationUserSummary.recordID(ownerUserID: $0, conversationID: conversationID)
        }
        let existingSummaries = try await ConversationUserSummary.query(on: readModelDatabase)
            .filter(\.$id ~~ summaryRecordIDs)
            .all()
        let existingSummariesByID = Dictionary(uniqueKeysWithValues: existingSummaries.compactMap { summary in
            summary.id.map { ($0, summary) }
        })
        let updatedAt = Date()
        var changeLogRows: [ConversationChangeLogBatchWriter.Row] = []
        changeLogRows.reserveCapacity(uniqueUserIDs.count)
        var summariesToUpsert: [(summary: ConversationUserSummary, exists: Bool)] = []
        summariesToUpsert.reserveCapacity(uniqueUserIDs.count)

        for recipientUserID in uniqueUserIDs {
            guard let membership = membershipsByUserID[recipientUserID] else {
                continue
            }

            let directPeer = conversation.conversationKind == .direct
                ? directPeer(
                    from: memberships,
                    currentUserID: recipientUserID,
                    usersByID: usersByID
                )
                : nil
            let lastVisibleMessage = latestMessageByVisibleFrom[membership.visibleFromSequence] ?? nil
            let preview = try lastVisibleMessage.map(makePreview)
            let latestVisibleSequence = max(
                lastVisibleMessage?.serverSequence ?? 0,
                max(0, membership.visibleFromSequence - 1)
            )
            let effectiveLastReadSequence = max(
                membership.lastReadSequence,
                max(0, membership.visibleFromSequence - 1)
            )
            let recordID = ConversationUserSummary.recordID(
                ownerUserID: recipientUserID,
                conversationID: conversationID
            )
            let existing = existingSummariesByID[recordID]
            let summary = try existing ?? ConversationUserSummary(
                ownerUserID: recipientUserID,
                conversationID: conversationID,
                title: conversation.title,
                kind: conversation.kind,
                directMessagingState: conversation.conversationKind == .direct ? conversation.directMessagingState : nil,
                groupLifecycleState: conversation.groupLifecycleStateEnum,
                directPeerUserID: directPeer?.id,
                directPeerEmail: directPeer?.email,
                directPeerDisplayName: directPeer?.displayName,
                directPeerAvatarPreset: directPeer?.avatarPreset,
                notice: conversation.notice,
                avatarPreset: conversation.avatarPresetEnum,
                muteAll: conversation.muteAll,
                memberUserIDs: storedMemberUserIDs,
                memberCount: memberUserIDs.count,
                lastMessage: preview,
                lastReadSequence: effectiveLastReadSequence,
                unreadCount: max(0, latestVisibleSequence - effectiveLastReadSequence),
                isPinned: membership.isPinned,
                pinnedAt: membership.pinnedAt,
                isMuted: membership.isMuted,
                lastActivityAt: preview?.createdAt ?? conversation.updatedAt,
                updatedAt: updatedAt,
                isRemoved: false,
                membershipRevision: conversation.membershipRevision
            )
            summary.ownerUserID = recipientUserID
            summary.conversationID = conversationID
            summary.title = conversation.title
            summary.kind = conversation.kind
            summary.directMessagingState = conversation.conversationKind == .direct ? conversation.directMessagingState : nil
            summary.groupLifecycleStateEnum = conversation.groupLifecycleStateEnum
            summary.directPeerUserID = directPeer?.id
            summary.directPeerEmail = directPeer?.email
            summary.directPeerDisplayName = directPeer?.displayName
            summary.directPeerAvatarPresetEnum = directPeer?.avatarPreset
            summary.notice = conversation.notice
            summary.avatarPresetEnum = conversation.avatarPresetEnum
            summary.muteAll = conversation.muteAll
            summary.memberUserIDs = storedMemberUserIDs
            summary.memberCount = memberUserIDs.count
            summary.membershipRevision = conversation.membershipRevision
            summary.lastMessage = preview
            summary.lastReadSequence = effectiveLastReadSequence
            summary.unreadCount = max(0, latestVisibleSequence - effectiveLastReadSequence)
            summary.isPinned = membership.isPinned
            summary.pinnedAt = membership.pinnedAt
            summary.isMuted = membership.isMuted
            summary.lastActivityAt = preview?.createdAt ?? conversation.updatedAt
            summary.updatedAt = updatedAt
            summary.isRemoved = false
            summariesToUpsert.append((summary: summary, exists: existing != nil))
            if writeChangeLog {
                changeLogRows.append(
                    ConversationChangeLogBatchWriter.Row(
                        ownerUserID: recipientUserID,
                        conversationID: conversationID,
                        summaryRecordID: summary.id ?? ConversationUserSummary.recordID(
                            ownerUserID: recipientUserID,
                            conversationID: conversationID
                        ),
                        updatedAt: updatedAt,
                        isRemoved: false
                    )
                )
            }
        }
        try await upsertMessageCreatedSummaries(summariesToUpsert, on: readModelDatabase)
        try await ConversationChangeLogBatchWriter(database: readModelDatabase).upsert(changeLogRows)
    }

    private func memberUserIDsForSummaryStorage(
        _ memberUserIDs: [UUID],
        conversationKind: IMConversationKind
    ) -> [UUID] {
        guard conversationKind == .group,
              storedMemberUserIDsLimit > 0,
              memberUserIDs.count > storedMemberUserIDsLimit
        else {
            return memberUserIDs
        }
        return []
    }

    @discardableResult
    func applyReadAdvanced(
        conversationID: UUID,
        recipientUserID: UUID,
        on database: (any Database)? = nil,
        writeChangeLog: Bool = true
    ) async throws -> Bool {
        let database = database ?? sourceDB
        let readModelDatabase = readModelDB
        let recordID = ConversationUserSummary.recordID(
            ownerUserID: recipientUserID,
            conversationID: conversationID
        )
        guard let summary = try await ConversationUserSummary.find(recordID, on: readModelDatabase) else {
            try await refreshConversationSummaries(
                conversationID: conversationID,
                recipientUserIDs: [recipientUserID],
                on: database,
                writeChangeLog: writeChangeLog
            )
            return false
        }
        guard let membership = try await ConversationMember.query(on: database)
            .filter(\.$conversation.$id == conversationID)
            .filter(\.$user.$id == recipientUserID)
            .first()
        else {
            try await markConversationRemoved(
                conversationID: conversationID,
                recipientUserID: recipientUserID,
                on: database,
                writeChangeLog: writeChangeLog
            )
            return false
        }

        let visibleLowerBound = max(0, membership.visibleFromSequence - 1)
        let activity = try await ConversationActivitySummary.find(conversationID, on: readModelDatabase)
        let activityLastSequence = activity.map { UInt64(max(0, $0.lastMessageServerSequence)) } ?? 0
        let latestVisibleSequence = max(
            summary.lastMessage?.serverSequence ?? 0,
            activityLastSequence,
            UInt64(visibleLowerBound)
        )
        let effectiveLastReadSequence = max(
            membership.lastReadSequence,
            visibleLowerBound
        )
        let updatedAt = Date()
        summary.lastReadSequence = effectiveLastReadSequence
        let unreadCount = latestVisibleSequence > UInt64(effectiveLastReadSequence)
            ? latestVisibleSequence - UInt64(effectiveLastReadSequence)
            : 0
        summary.unreadCount = try imIntSequence(unreadCount, field: "unread_count")
        summary.updatedAt = updatedAt
        summary.isRemoved = false
        try await save(summary, on: readModelDatabase)
        if writeChangeLog {
            try await upsertChangeLog(
                ownerUserID: recipientUserID,
                conversationID: conversationID,
                summaryRecordID: recordID,
                updatedAt: updatedAt,
                isRemoved: false,
                on: readModelDatabase
            )
        }
        return true
    }

    func markConversationRemoved(
        conversationID: UUID,
        recipientUserID: UUID,
        on database: (any Database)? = nil,
        writeChangeLog: Bool = true
    ) async throws {
        _ = database ?? sourceDB
        let readModelDatabase = readModelDB
        let summary = try await findOrCreateSummary(
            ownerUserID: recipientUserID,
            conversationID: conversationID,
            on: readModelDatabase
        )
        summary.ownerUserID = recipientUserID
        summary.conversationID = conversationID
        summary.isRemoved = true
        summary.updatedAt = Date()
        try await save(summary, on: readModelDatabase)
        if writeChangeLog {
            try await upsertChangeLog(
                ownerUserID: recipientUserID,
                conversationID: conversationID,
                summaryRecordID: summary.id ?? ConversationUserSummary.recordID(
                    ownerUserID: recipientUserID,
                    conversationID: conversationID
                ),
                updatedAt: summary.updatedAt,
                isRemoved: true,
                on: readModelDatabase
            )
        }
    }

    func refreshDirectPeerProfiles(for userID: UUID) async throws -> [UUID: [UUID]] {
        let summaries = try await ConversationUserSummary.query(on: readModelDB)
            .filter(\.$directPeerUserID == userID)
            .all()
        guard !summaries.isEmpty else {
            return [:]
        }

        guard let user = try await User.find(userID, on: userDirectoryDB) else {
            return [:]
        }

        var recipientUserIDsByConversationID: [UUID: [UUID]] = [:]
        for summary in summaries {
            summary.directPeerEmail = user.email
            summary.directPeerDisplayName = user.displayName
            summary.directPeerAvatarPresetEnum = user.avatarPresetEnum
            summary.updatedAt = Date()
            try await save(summary, on: readModelDB)
            try await upsertChangeLog(
                ownerUserID: summary.ownerUserID,
                conversationID: summary.conversationID,
                summaryRecordID: summary.id ?? ConversationUserSummary.recordID(
                    ownerUserID: summary.ownerUserID,
                    conversationID: summary.conversationID
                ),
                updatedAt: summary.updatedAt,
                isRemoved: summary.isRemoved,
                on: readModelDB
            )
            recipientUserIDsByConversationID[summary.conversationID, default: []].append(summary.ownerUserID)
        }

        return recipientUserIDsByConversationID.mapValues { ownerUserIDs in
            Array(Set(ownerUserIDs)).sorted { $0.uuidString < $1.uuidString }
        }
    }
}
