import Foundation
import IMClientKit

struct IMConversationListSnapshot: Equatable {
    let generation: UInt64
    let filter: IMConversationListFilter
    let rows: [IMConversationRowSnapshot]

    init(
        generation: UInt64,
        filter: IMConversationListFilter,
        rows: [IMConversationRowSnapshot]
    ) {
        self.generation = generation
        self.filter = filter
        self.rows = rows
    }
}

struct IMConversationRowSnapshot: Identifiable, Equatable {
    enum PreviewTone: Equatable {
        case normal
        case unread
        case draft
        case failure
    }

    let id: String
    let kind: IMConversationKind
    let title: String
    let rowSecondaryLabel: String?
    let memberCount: Int
    let directPeerEmail: String?
    let directPeerAvatarPreset: UserAvatarPreset?
    let avatarPreset: IMConversationAvatarPreset?
    let primaryPreviewText: String
    let primaryPreviewTone: PreviewTone
    let updatedAt: Date
    let unreadCount: Int
    let isPinned: Bool
    let isMuted: Bool
    let isActive: Bool
    let isDirectMessagingFrozen: Bool
    let directMessagingStatusMessage: String?
    let queueSummary: IMConversationQueueSummary
    let pendingMessageCount: Int
    let messageCount: Int
    let timelineItemCount: Int

    var debugSignature: String {
        [
            id,
            "\(unreadCount)",
            primaryPreviewText,
            "\(updatedAt.timeIntervalSince1970)",
            "\(pendingMessageCount)",
            "\(messageCount)",
            "\(timelineItemCount)",
            "\(isActive)"
        ].joined(separator: "|")
    }
}

struct IMConversationListSnapshotBuilder {
    func build(
        conversations: [IMConversation],
        selectedConversationID: String?,
        filter: IMConversationListFilter,
        generation: UInt64,
        identityForConversation: (IMConversation) -> IMConversationIdentityPresentation,
        queueSummaryForConversationID: (String) -> IMConversationQueueSummary
    ) -> IMConversationListSnapshot {
        let displayedConversations: [IMConversation]
        switch filter {
        case .all:
            displayedConversations = conversations
        case .groups:
            displayedConversations = conversations.filter { $0.kind == .group }
        case .unread:
            displayedConversations = conversations.filter { $0.unreadCount > 0 }
        }

        return IMConversationListSnapshot(
            generation: generation,
            filter: filter,
            rows: displayedConversations.map { conversation in
                let identity = identityForConversation(conversation)
                let queueSummary = queueSummaryForConversationID(conversation.id)
                return rowSnapshot(
                    conversation: conversation,
                    identity: identity,
                    queueSummary: queueSummary,
                    isActive: conversation.id == selectedConversationID
                )
            }
        )
    }

    private func rowSnapshot(
        conversation: IMConversation,
        identity: IMConversationIdentityPresentation,
        queueSummary: IMConversationQueueSummary,
        isActive: Bool
    ) -> IMConversationRowSnapshot {
        let draft = conversation.draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        let preview = conversation.lastMessagePreview.trimmingCharacters(in: .whitespacesAndNewlines)
        let primaryPreview: (text: String, tone: IMConversationRowSnapshot.PreviewTone)

        if !draft.isEmpty {
            primaryPreview = ("草稿: \(draft)", .draft)
        } else if queueSummary.retryableIssueCount > 0 {
            primaryPreview = ("发送失败，点进会话重试", .failure)
        } else if preview.isEmpty {
            primaryPreview = (
                conversation.kind == .group ? "\(conversation.memberCount) 位成员" : "暂无消息",
                conversation.unreadCount > 0 ? .unread : .normal
            )
        } else {
            primaryPreview = (
                preview,
                conversation.unreadCount > 0 ? .unread : .normal
            )
        }

        return IMConversationRowSnapshot(
            id: conversation.id,
            kind: conversation.kind,
            title: identity.title,
            rowSecondaryLabel: identity.rowSecondaryLabel,
            memberCount: conversation.memberCount,
            directPeerEmail: conversation.directPeer?.email,
            directPeerAvatarPreset: conversation.directPeer?.avatarPreset,
            avatarPreset: conversation.avatarPreset,
            primaryPreviewText: primaryPreview.text,
            primaryPreviewTone: primaryPreview.tone,
            updatedAt: conversation.updatedAt,
            unreadCount: conversation.unreadCount,
            isPinned: conversation.isPinned,
            isMuted: conversation.isMuted,
            isActive: isActive,
            isDirectMessagingFrozen: conversation.isDirectMessagingFrozen,
            directMessagingStatusMessage: conversation.directMessagingStatusMessage,
            queueSummary: queueSummary,
            pendingMessageCount: conversation.pendingMessages.count,
            messageCount: conversation.messages.count,
            timelineItemCount: conversation.timelineItems.count
        )
    }
}

@MainActor
extension IMConversationStore {
    func conversationListSnapshot(
        filter: IMConversationListFilter,
        identityForConversation: (IMConversation) -> IMConversationIdentityPresentation
    ) -> IMConversationListSnapshot {
        IMConversationListSnapshotBuilder().build(
            conversations: filteredConversations,
            selectedConversationID: selectedConversationID,
            filter: filter,
            generation: conversationMutationGeneration,
            identityForConversation: identityForConversation,
            queueSummaryForConversationID: { conversationID in
                self.queueSummary(for: conversationID)
            }
        )
    }
}
