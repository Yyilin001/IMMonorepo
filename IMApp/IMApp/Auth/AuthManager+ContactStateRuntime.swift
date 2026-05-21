import Combine
import Foundation
import IMClientKit
import SwiftUI
import UIKit

private enum ContactStateRuntimeTiming {
    static let correctionDebounceNanoseconds: UInt64 = 400_000_000
    static let cachePersistDebounceNanoseconds: UInt64 = 300_000_000
}

@MainActor
extension AuthManager {
    func syncContactStateAfterConnection() async {
        guard currentUser != nil else {
            return
        }

        await reloadContacts()
        await reloadContactRequests()
        await loadBlockedUsers()
    }

    func scheduleContactStateCorrection(force: Bool = false, reason _: String? = nil) {
        contactStateCorrectionTask?.cancel()
        contactStateCorrectionTask = Task { [weak self] in
            guard let self else {
                return
            }

            if !force {
                try? await Task.sleep(nanoseconds: ContactStateRuntimeTiming.correctionDebounceNanoseconds)
            }

            guard !Task.isCancelled else {
                return
            }

            await self.syncContactStateAfterConnection()
            self.contactStateCorrectionTask = nil
        }
    }

    func setDirectConversationRelationshipActionMessage(_ message: String?, for conversationID: String) {
        if let message, !message.isEmpty {
            directConversationRelationshipActionMessages[conversationID] = message
        } else {
            directConversationRelationshipActionMessages.removeValue(forKey: conversationID)
        }
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
        contactStore.upsertContact(contact)
    }

    func applyContactEvent(_ payload: IMTCPContactEventPayload) {
        let result = contactStore.apply(
            event: payload,
            currentUserID: currentUser?.id,
            isRelevant: { request, currentUserID in
                sessionFacade.isRequestRelevant(request, to: currentUserID)
            },
            normalize: { requests, currentUserID in
                sessionFacade.normalizeRequests(requests, currentUserID: currentUserID)
            },
            sortPendingNewestFirst: { lhs, rhs in
                sessionFacade.sortPendingNewestFirst(lhs, rhs)
            }
        )

        switch result {
        case .applied:
            scheduleContactStateCachePersist()
        case .needsCorrection(let reason):
            scheduleContactStateCorrection(reason: reason)
        case .ignored:
            break
        }
    }

    func replaceContactRequests(_ requests: [ContactRequestResponseBody], currentUserID: UUID) {
        contactStore.replaceRequests(
            requests,
            currentUserID: currentUserID,
            normalize: { requests, currentUserID in
                sessionFacade.normalizeRequests(requests, currentUserID: currentUserID)
            }
        )
        recomputeIncomingContactRequestUnreadState()
    }

    func upsertContactRequest(_ request: ContactRequestResponseBody) {
        guard let currentUserID = currentUser?.id else {
            return
        }

        contactStore.upsertRequest(
            request,
            currentUserID: currentUserID,
            isRelevant: { request, currentUserID in
                sessionFacade.isRequestRelevant(request, to: currentUserID)
            },
            normalize: { requests, currentUserID in
                sessionFacade.normalizeRequests(requests, currentUserID: currentUserID)
            }
        )
        recomputeIncomingContactRequestUnreadState()
    }

    func updateContactRequestStatus(
        id requestID: UUID,
        status: ContactRequestStatus,
        respondedAt: Date
    ) {
        guard let currentUserID = currentUser?.id else {
            return
        }
        contactStore.updateRequestStatus(
            id: requestID,
            status: status,
            respondedAt: respondedAt,
            currentUserID: currentUserID,
            normalize: { requests, currentUserID in
                sessionFacade.normalizeRequests(requests, currentUserID: currentUserID)
            }
        )
        recomputeIncomingContactRequestUnreadState()
    }

    func scheduleContactStateCachePersist() {
        guard currentUser != nil else {
            return
        }

        contactStateCachePersistTask?.cancel()
        contactStateCachePersistTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: ContactStateRuntimeTiming.cachePersistDebounceNanoseconds)
            guard !Task.isCancelled else {
                return
            }
            await self?.flushContactStateCache()
        }
    }

    func flushContactStateCache() async {
        contactStateCachePersistTask?.cancel()
        contactStateCachePersistTask = nil

        guard let user = currentUser else {
            return
        }

        do {
            try await sessionFacade.saveContactStateCacheSnapshot(
                makeContactStateCacheSnapshot(),
                for: user.id
            )
        } catch {
            // Ignore cache persistence failures and keep the in-memory state authoritative.
        }
    }

    func makeContactStateCacheSnapshot() -> ContactStateCacheSnapshot {
        ContactStateCacheSnapshot(
            contacts: contacts.map(CachedContactState.init),
            incomingRequests: incomingPendingContactRequests.map(CachedContactRequestState.init),
            outgoingRequests: outgoingPendingContactRequests.map(CachedContactRequestState.init),
            resolvedRequests: recentResolvedContactRequests.map(CachedContactRequestState.init),
            lastRefreshAt: lastContactStateRefreshAt,
            lastSeenIncomingContactRequestAt: lastSeenIncomingContactRequestAt
        )
    }

    var latestIncomingContactRequestAt: Date? {
        incomingPendingContactRequests.compactMap(\.createdAt).max()
    }

    func recomputeIncomingContactRequestUnreadState() {
        guard let currentUserID = currentUser?.id else {
            unseenIncomingContactRequestCount = 0
            return
        }
        contactStore.recomputeIncomingUnread(
            currentUserID: currentUserID,
            sortPendingNewestFirst: { lhs, rhs in
                sessionFacade.sortPendingNewestFirst(lhs, rhs)
            }
        )
    }
}
