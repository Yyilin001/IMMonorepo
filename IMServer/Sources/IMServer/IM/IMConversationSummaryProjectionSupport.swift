import Fluent
import Foundation
import Vapor

extension IMConversationSummaryProjectionService {
    func findOrCreateSummary(
        ownerUserID: UUID,
        conversationID: UUID,
        on database: any Database
    ) async throws -> ConversationUserSummary {
        let recordID = ConversationUserSummary.recordID(ownerUserID: ownerUserID, conversationID: conversationID)
        if let existing = try await ConversationUserSummary.find(recordID, on: database) {
            return existing
        }

        return try ConversationUserSummary(
            ownerUserID: ownerUserID,
            conversationID: conversationID,
            title: nil,
            kind: IMConversationKind.group.rawValue,
            directMessagingState: nil,
            directPeerUserID: nil,
            directPeerEmail: nil,
            directPeerDisplayName: nil,
            directPeerAvatarPreset: nil,
            notice: nil,
            avatarPreset: nil,
            memberUserIDs: [],
            lastMessage: nil,
            lastReadSequence: 0,
            unreadCount: 0,
            isPinned: false,
            pinnedAt: nil,
            isMuted: false,
            lastActivityAt: .distantPast,
            updatedAt: .distantPast,
            isRemoved: false
        )
    }

    func save(_ summary: ConversationUserSummary, on database: any Database) async throws {
        if try await ConversationUserSummary.find(summary.id, on: database) == nil {
            try await summary.create(on: database)
        } else {
            try await summary.update(on: database)
        }
    }

    func upsertChangeLog(
        ownerUserID: UUID,
        conversationID: UUID,
        summaryRecordID: String,
        updatedAt: Date,
        isRemoved: Bool,
        on database: any Database
    ) async throws {
        let recordID = ConversationChangesLogEntry.recordID(ownerUserID: ownerUserID, conversationID: conversationID)
        let entry = try await ConversationChangesLogEntry.find(recordID, on: database)
            ?? ConversationChangesLogEntry(
                ownerUserID: ownerUserID,
                conversationID: conversationID,
                summaryRecordID: summaryRecordID,
                updatedAt: updatedAt,
                isRemoved: isRemoved
            )
        entry.ownerUserID = ownerUserID
        entry.conversationID = conversationID
        entry.summaryRecordID = summaryRecordID
        entry.updatedAt = updatedAt
        entry.isRemoved = isRemoved

        if try await ConversationChangesLogEntry.find(recordID, on: database) == nil {
            try await entry.create(on: database)
        } else {
            try await entry.update(on: database)
        }

        let targetToken = Self.encodeChangeToken(
            ChangeToken(updatedAt: updatedAt, recordID: recordID)
        )
        let tokenRecordID = ConversationReadModelToken.recordID(ownerUserID: ownerUserID)
        let token = try await ConversationReadModelToken.find(tokenRecordID, on: database)
            ?? ConversationReadModelToken(ownerUserID: ownerUserID, targetToken: targetToken, updatedAt: updatedAt)
        token.ownerUserID = ownerUserID
        token.targetToken = targetToken
        token.updatedAt = updatedAt
        if try await ConversationReadModelToken.find(tokenRecordID, on: database) == nil {
            try await token.create(on: database)
        } else {
            try await token.update(on: database)
        }
    }

    func directPeer(
        from memberships: [ConversationMember],
        currentUserID: UUID
    ) -> IMDirectPeerResponse? {
        guard let peerMembership = memberships.first(where: { $0.$user.id != currentUserID }),
              let peer = peerMembership.$user.value
        else {
            return nil
        }

        return IMDirectPeerResponse(
            id: peerMembership.$user.id,
            email: peer.email,
            displayName: peer.displayName,
            avatarPreset: peer.avatarPresetEnum
        )
    }

    func makePreview(from message: ConversationMessage) throws -> IMMessagePreviewResponse {
        let content = try message.decodedContent()
        let derivedState = try message.decodedDerivedState()
        return IMMessagePreviewResponse(
            id: try message.requireID(),
            senderUserID: message.$sender.id,
            serverSequence: message.serverSequence,
            content: content,
            derivedState: derivedState,
            createdAt: message.createdAt
        )
    }
}
