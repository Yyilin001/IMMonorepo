import Foundation
import IMClientKit
import SwiftUI
import UIKit

@MainActor
extension AuthManager {
    func syncContactStateAfterConnection() async {
        await contactRuntimeController.syncAfterConnection()
    }

    func scheduleContactStateCorrection(force: Bool = false, reason _: String? = nil) {
        contactRuntimeController.scheduleCorrection(force: force)
    }

    func normalizedConversationTitle(_ title: String, conversationID: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "会话 \(conversationID.prefix(8))"
        }
        return trimmed
    }

    func fallbackSummary(for conversation: IMConversation) -> String {
        if !conversation.members.isEmpty {
            return conversation.members.map(\.email).joined(separator: "、")
        }

        if conversation.memberCount > 0 {
            return "\(conversation.memberCount) 位成员"
        }

        if !conversation.memberUserIDs.isEmpty {
            return "\(conversation.memberUserIDs.count) 位成员"
        }

        return "当前还没有成员信息"
    }

    func groupConversationSummary(for conversation: IMConversation) -> String {
        if !conversation.members.isEmpty {
            return conversation.members.map(\.email).joined(separator: "、")
        }

        if conversation.memberCount > 0 {
            return "成员 \(conversation.memberCount) 人"
        }

        if !conversation.memberUserIDs.isEmpty {
            return "成员 \(conversation.memberUserIDs.count) 人"
        }

        return "当前还没有成员信息"
    }

    func directConversationPeer(
        in conversation: IMConversation,
        currentUserID: UUID
    ) -> IMDirectPeer? {
        if let directPeer = conversation.directPeer,
           directPeer.id != currentUserID {
            return directPeer
        }

        guard let member = conversation.members.first(where: { $0.id != currentUserID }) else {
            return nil
        }

        return IMDirectPeer(id: member.id, email: member.email)
    }

    func conversationStoreIsLoadingDirectPeer(for conversationID: String) -> Bool {
        imConversationStore.isLoadingMembers && imConversationStore.selectedConversationID == conversationID
    }

    func ensureDirectConversationPeer(for conversationID: String) async -> IMDirectPeer? {
        guard let currentUser,
              let conversation = imConversationStore.conversations.first(where: { $0.id == conversationID }),
              conversation.kind == .direct
        else {
            return nil
        }

        if let peer = directConversationPeer(in: conversation, currentUserID: currentUser.id) {
            return peer
        }

        await conversationRuntimeController.loadConversationMembers(for: conversationID)

        guard let refreshedConversation = imConversationStore.conversations.first(where: { $0.id == conversationID }) else {
            return nil
        }

        return directConversationPeer(in: refreshedConversation, currentUserID: currentUser.id)
    }

    func upsertContact(_ contact: ContactResponseBody) {
        contactRuntimeController.upsertContact(contact)
    }

    func applyContactDomainEvent(_ payload: IMTCPChatDomainEventPayload) {
        contactRuntimeController.applyContactDomainEvent(payload)
    }

    func replaceContactRequests(_ requests: [ContactRequestResponseBody], currentUserID: UUID) {
        contactRuntimeController.replaceContactRequests(requests, currentUserID: currentUserID)
    }

    func upsertContactRequest(_ request: ContactRequestResponseBody) {
        contactRuntimeController.upsertContactRequest(request)
    }

    func updateContactRequestStatus(
        id requestID: UUID,
        status: ContactRequestStatus,
        respondedAt: Date
    ) {
        contactRuntimeController.updateContactRequestStatus(
            id: requestID,
            status: status,
            respondedAt: respondedAt
        )
    }

    func scheduleContactStateCachePersist() {
        contactRuntimeController.scheduleCachePersist()
    }

    func flushContactStateCache() async {
        await contactRuntimeController.flushCache()
    }

    func makeContactStateCacheSnapshot() -> ContactStateCacheSnapshot {
        contactRuntimeController.makeCacheSnapshot()
    }

    var latestIncomingContactRequestAt: Date? {
        contactRuntimeController.latestIncomingContactRequestAt
    }

    func recomputeIncomingContactRequestUnreadState() {
        contactRuntimeController.recomputeIncomingUnreadState()
    }
}
