import SwiftUI
import IMClientKit

extension IMConversationDetailView {
    var conversationIdentity: IMConversationIdentityPresentation {
        if let identity = presentationStore.conversationIdentityPresentation(for: conversationID) {
            return identity
        }

        return IMConversationIdentityPresentation(
            title: chatPageSnapshot.metadata.title,
            detailSummary: chatPageSnapshot.isLoadingMembers ? "正在加载成员信息" : "当前还没有成员信息",
            rowSecondaryLabel: nil
        )
    }

    var conversationKindText: String {
        chatPageSnapshot.contextSnapshot.kindText
    }

    var conversationKindIcon: String {
        chatPageSnapshot.contextSnapshot.kindIcon
    }

    var conversationInitials: String {
        let trimmed = conversationIdentity.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "IM"
        }

        return String(trimmed.prefix(2)).uppercased()
    }

    var canSendMessages: Bool {
        chatPageSnapshot.canSendMessages
    }

    var composerDisabledReason: String? {
        chatPageSnapshot.composerDisabledReason
    }

    var composerSnapshot: IMConversationComposerSnapshot {
        IMConversationComposerSnapshot(
            text: composerText,
            canSendMessages: canSendMessages,
            disabledReason: composerDisabledReason,
            replyTarget: replyTarget,
            editingTarget: editingTarget
        )
    }

    var currentGroupRole: IMConversationMemberRole? {
        chatPageSnapshot.currentGroupRole
    }

    var currentMemberNickname: String? {
        chatPageSnapshot.currentMemberNickname
    }

    var directPeer: IMChatDirectPeerSnapshot? {
        chatPageSnapshot.directPeerSnapshot
    }

    var isDirectPeerBlocked: Bool {
        chatPageSnapshot.isDirectPeerBlocked
    }

    var canAddMembers: Bool {
        chatPageSnapshot.canAddMembers
    }

    var canRenameConversation: Bool {
        chatPageSnapshot.canRenameConversation
    }

    var canManageMembers: Bool {
        chatPageSnapshot.canManageMembers
    }

    var directMessagingStatusMessage: String? {
        chatPageSnapshot.contextSnapshot.directMessagingStatusMessage
    }

    var directRelationshipPresentation: DirectPeerRelationshipPresentation? {
        presentationStore.directPeerRelationshipPresentation(for: conversationID)
    }

    var directRelationshipNotice: DirectRelationshipNotice? {
        presentationStore.directRelationshipNotice(for: conversationID)
    }

    var connectionStatusText: String {
        switch presentationStore.imConnectionStatus {
        case .connected:
            return "实时连接在线"
        case .connecting:
            return "正在建立实时连接"
        case .disconnected:
            return "当前仅可查看 HTTP 拉取的数据"
        case .failed(let message):
            return message
        }
    }

    var connectionStatusIcon: String {
        switch presentationStore.imConnectionStatus {
        case .connected:
            return "dot.radiowaves.left.and.right"
        case .connecting:
            return "arrow.trianglehead.2.clockwise"
        case .disconnected:
            return "bolt.slash"
        case .failed:
            return "exclamationmark.triangle.fill"
        }
    }

    var connectionStatusColor: Color {
        switch presentationStore.imConnectionStatus {
        case .connected:
            return .green
        case .connecting:
            return .blue
        case .disconnected:
            return .secondary
        case .failed:
            return .orange
        }
    }

}
