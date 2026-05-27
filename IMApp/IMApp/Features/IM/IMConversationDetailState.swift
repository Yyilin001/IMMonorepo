import SwiftUI
import IMClientKit

extension IMConversationDetailView {
    var conversationIdentity: IMConversationIdentityPresentation {
        guard let conversation else {
            return IMConversationIdentityPresentation(
                title: "会话",
                detailSummary: conversationStore.isLoadingMembers ? "正在加载成员信息" : "当前还没有成员信息",
                rowSecondaryLabel: nil
            )
        }

        return presentationStore.conversationIdentityPresentation(for: conversation)
    }

    var conversationKindText: String {
        switch conversation?.kind ?? .group {
        case .direct:
            return "私聊"
        case .group:
            return "群聊"
        }
    }

    var conversationKindIcon: String {
        switch conversation?.kind ?? .group {
        case .direct:
            return "person.2"
        case .group:
            return "person.3"
        }
    }

    var conversationInitials: String {
        let trimmed = conversationIdentity.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "IM"
        }

        return String(trimmed.prefix(2)).uppercased()
    }

    var canSendMessages: Bool {
        guard let conversation else {
            return true
        }
        if conversation.kind == .group {
            return !(conversation.muteAll && currentGroupRole == .member)
        }
        if isDirectPeerBlocked {
            return false
        }
        return conversation.canSendMessages
    }

    var composerDisabledReason: String? {
        if isDirectPeerBlocked {
            return "已屏蔽对方"
        }
        guard conversation?.kind == .group,
              conversation?.muteAll == true,
              currentGroupRole == .member
        else {
            return nil
        }
        return "全员禁言中"
    }

    var currentGroupRole: IMConversationMemberRole? {
        currentMember?.role
    }

    var currentMember: IMConversationMember? {
        guard let currentUserID = runtimeStore.currentUserID else {
            return nil
        }

        return conversation?.members.first(where: { $0.id == currentUserID })
    }

    var directPeer: IMDirectPeer? {
        guard conversation?.kind == .direct else {
            return nil
        }
        return conversation?.directPeer
    }

    var isDirectPeerBlocked: Bool {
        guard let directPeer else {
            return false
        }
        return runtimeStore.blockedUserIDs.contains(directPeer.id)
    }

    var canAddMembers: Bool {
        currentGroupRole?.canAddMembers ?? false
    }

    var canRenameConversation: Bool {
        currentGroupRole?.canRenameConversation ?? false
    }

    var canManageMembers: Bool {
        currentGroupRole?.canManageRoles == true || currentGroupRole?.canAddMembers == true
    }

    var directMessagingStatusMessage: String? {
        conversation?.directMessagingStatusMessage
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

    func replyReference(from message: IMConversationMessage) -> IMReplyReference? {
        guard message.canReply else {
            return nil
        }

        return IMReplyReference(
            messageID: message.serverMessageID,
            senderUserID: message.senderUserID,
            previewText: replyComposerPreviewText(for: message)
        )
    }

    func replyComposerPreviewText(for message: IMConversationMessage) -> String {
        if message.derivedState.isRecalled {
            return "原消息已撤回"
        }

        let preview = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return preview.isEmpty ? "原消息暂不可用" : preview
    }
}
