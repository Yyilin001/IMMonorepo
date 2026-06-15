import Foundation
import IMClientKit

/// Trimmed status message safe to render from sheet and list snapshots.
struct IMConversationStatusSnapshot: Equatable, Sendable {
    let message: String?

    init(message: String?) {
        let trimmedMessage = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.message = trimmedMessage.isEmpty ? nil : trimmedMessage
    }
}

/// Immutable conversation-list projection consumed by SwiftUI.
///
/// Rows and list metadata are committed together so loading, pagination, search,
/// and active-row state cannot drift between separate store reads during render.
struct IMConversationListSnapshot: Equatable, Sendable {
    let generation: UInt64
    let filter: IMConversationListFilter
    let statusMessage: String?
    let isLoadingConversations: Bool
    let isLoadingMoreConversationSummaries: Bool
    let hasMoreConversationSummaries: Bool
    let searchText: String
    let rows: [IMConversationRowSnapshot]

    init(
        generation: UInt64,
        filter: IMConversationListFilter,
        statusMessage: String? = nil,
        isLoadingConversations: Bool = false,
        isLoadingMoreConversationSummaries: Bool = false,
        hasMoreConversationSummaries: Bool = false,
        searchText: String = "",
        rows: [IMConversationRowSnapshot]
    ) {
        self.generation = generation
        self.filter = filter
        self.statusMessage = statusMessage
        self.isLoadingConversations = isLoadingConversations
        self.isLoadingMoreConversationSummaries = isLoadingMoreConversationSummaries
        self.hasMoreConversationSummaries = hasMoreConversationSummaries
        self.searchText = searchText
        self.rows = rows
    }
}

/// Stable row value for one conversation in the list.
///
/// The row contains only presentation fields and action flags; views should not
/// reach back into `IMConversation` while rendering a cell.
struct IMConversationRowSnapshot: Identifiable, Equatable, Sendable {
    enum PreviewTone: Equatable, Sendable {
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

/// Projects store conversations into list snapshots for a selected filter.
///
/// Raw conversation objects are accepted only at this boundary and are converted
/// into stable row values before SwiftUI observes them.
struct IMConversationListSnapshotBuilder {
    func build(
        conversations: [IMConversation],
        selectedConversationID: String?,
        filter: IMConversationListFilter,
        generation: UInt64,
        statusMessage: String? = nil,
        isLoadingConversations: Bool = false,
        isLoadingMoreConversationSummaries: Bool = false,
        hasMoreConversationSummaries: Bool = false,
        searchText: String = "",
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
            statusMessage: statusMessage,
            isLoadingConversations: isLoadingConversations,
            isLoadingMoreConversationSummaries: isLoadingMoreConversationSummaries,
            hasMoreConversationSummaries: hasMoreConversationSummaries,
            searchText: searchText,
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
            statusMessage: statusMessage,
            isLoadingConversations: isLoadingConversations,
            isLoadingMoreConversationSummaries: isLoadingMoreConversationSummaries,
            hasMoreConversationSummaries: hasMoreConversationSummaries,
            searchText: searchText,
            identityForConversation: identityForConversation,
            queueSummaryForConversationID: { conversationID in
                self.queueSummary(for: conversationID)
            }
        )
    }
}
