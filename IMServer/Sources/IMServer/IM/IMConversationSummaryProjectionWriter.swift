import Fluent
import Foundation
import SQLKit
import Vapor

extension IMConversationSummaryProjectionService {
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

            let currentLastSequence = summary.lastMessage?.serverSequence ?? 0
            if message.serverSequence >= currentLastSequence {
                summary.lastMessage = messagePreview
                summary.lastActivityAt = message.createdAt ?? updatedAt
            }

            let effectiveLastReadSequence = max(
                membership.lastReadSequence,
                max(0, membership.visibleFromSequence - 1)
            )
            let latestVisibleSequence = max(
                message.serverSequence,
                currentLastSequence,
                max(0, membership.visibleFromSequence - 1)
            )
            summary.lastReadSequence = effectiveLastReadSequence
            summary.unreadCount = max(0, latestVisibleSequence - effectiveLastReadSequence)
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
            .with(\.$user)
            .all()
        guard !memberships.isEmpty else {
            return
        }

        let memberUserIDs = memberships.map(\.$user.id).sorted { $0.uuidString < $1.uuidString }
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

            let directPeer = directPeer(from: memberships, currentUserID: recipientUserID)
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
                directPeerUserID: directPeer?.id,
                directPeerEmail: directPeer?.email,
                directPeerDisplayName: directPeer?.displayName,
                directPeerAvatarPreset: directPeer?.avatarPreset,
                notice: conversation.notice,
                avatarPreset: conversation.avatarPresetEnum,
                muteAll: conversation.muteAll,
                memberUserIDs: memberUserIDs,
                lastMessage: preview,
                lastReadSequence: effectiveLastReadSequence,
                unreadCount: max(0, latestVisibleSequence - effectiveLastReadSequence),
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
            summary.directPeerUserID = directPeer?.id
            summary.directPeerEmail = directPeer?.email
            summary.directPeerDisplayName = directPeer?.displayName
            summary.directPeerAvatarPresetEnum = directPeer?.avatarPreset
            summary.notice = conversation.notice
            summary.avatarPresetEnum = conversation.avatarPresetEnum
            summary.muteAll = conversation.muteAll
            summary.memberUserIDs = memberUserIDs
            summary.membershipRevision = conversation.membershipRevision
            summary.lastMessage = preview
            summary.lastReadSequence = effectiveLastReadSequence
            summary.unreadCount = max(0, latestVisibleSequence - effectiveLastReadSequence)
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

        let latestVisibleSequence = max(
            summary.lastMessage?.serverSequence ?? 0,
            max(0, membership.visibleFromSequence - 1)
        )
        let effectiveLastReadSequence = max(
            membership.lastReadSequence,
            max(0, membership.visibleFromSequence - 1)
        )
        let updatedAt = Date()
        summary.lastReadSequence = effectiveLastReadSequence
        summary.unreadCount = max(0, latestVisibleSequence - effectiveLastReadSequence)
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

        guard let user = try await User.find(userID, on: sourceDB) else {
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
