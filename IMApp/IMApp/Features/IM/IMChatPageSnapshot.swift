import Foundation
import IMClientKit

struct IMChatPageSnapshot: Equatable {
    let conversationID: String
    let generation: UInt64
    let conversation: IMConversation?
    fileprivate let messages: [IMConversationMessage]
    fileprivate let timelineItems: [IMConversationTimelineItem]
    let timelineRows: [IMChatTimelineRowSnapshot]
    let metrics: IMChatPageMetricsSnapshot
    let hasMoreHistory: Bool
    let queueSummary: IMConversationQueueSummary
    let receiptSummary: IMConversationReceiptSummaryResponseBody?
    let isLoadingMessages: Bool
    let isLoadingMembers: Bool
    let currentUserID: UUID?
    let blockedUserIDs: Set<UUID>

    var currentMember: IMConversationMember? {
        guard let currentUserID else {
            return nil
        }
        return conversation?.members.first { $0.id == currentUserID }
    }

    var currentGroupRole: IMConversationMemberRole? {
        currentMember?.role
    }

    var directPeer: IMDirectPeer? {
        guard conversation?.kind == .direct else {
            return nil
        }
        return conversation?.directPeer
    }

    var currentMemberNickname: String? {
        currentMember?.memberNickname
    }

    var directPeerSnapshot: IMChatDirectPeerSnapshot? {
        guard let directPeer else {
            return nil
        }
        return IMChatDirectPeerSnapshot(peer: directPeer)
    }

    var isDirectPeerBlocked: Bool {
        guard let directPeer else {
            return false
        }
        return blockedUserIDs.contains(directPeer.id)
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

    var latestItemID: String? {
        timelineRows.last?.id
    }

    var mediaDownloadSnapshots: [IMChatMediaDownloadSnapshot] {
        timelineRows.compactMap { row in
            guard case .message(let messageRow) = row else {
                return nil
            }
            return messageRow.mediaDownload
        }
    }

    var shouldShowLoadingState: Bool {
        timelineRows.isEmpty && isLoadingMessages
    }

    var latestTimelineItemIsCurrentUserOutgoing: Bool {
        guard let currentUserID,
              let latestItem = timelineRows.last
        else {
            return false
        }

        switch latestItem {
        case .message(let row):
            return row.direction == .outgoing && row.senderUserID == currentUserID
        case .pendingMessage(let row):
            return row.senderUserID == currentUserID
        case .notice:
            return false
        }
    }

    func deliveryOverrideText(for message: IMConversationMessage) -> String? {
        Self.deliveryOverrideText(
            for: message,
            conversationKind: conversation?.kind,
            receiptSummary: receiptSummary
        )
    }

    static func deliveryOverrideText(
        for message: IMConversationMessage,
        conversationKind: IMConversationKind?,
        receiptSummary: IMConversationReceiptSummaryResponseBody?
    ) -> String? {
        guard message.direction == .outgoing,
              message.deliveryState == .sent
        else {
            return nil
        }

        guard let receiptSummary else {
            return "已发送"
        }

        if receiptSummary.readThroughSequence >= message.serverSequence {
            return "已读"
        }
        if conversationKind == .group,
           receiptSummary.deliveredThroughSequence >= message.serverSequence {
            return receiptSummary.readThroughSequence > 0 ? "部分已读" : "已送达"
        }
        if receiptSummary.deliveredThroughSequence >= message.serverSequence {
            return "已送达"
        }
        return "已发送"
    }

    func messageRowSnapshot(
        for message: IMConversationMessage,
        isRetryableFailure: (IMConversationMessage) -> Bool
    ) -> IMChatMessageRowSnapshot {
        IMChatMessageRowSnapshot(
            content: IMChatMessageContentSnapshot(message: message),
            replyReference: message.resolvedReplyReference(in: messages),
            replyTarget: IMChatReplyTargetSnapshot(message: message),
            editingTarget: IMChatEditingTargetSnapshot(message: message),
            mediaDownload: IMChatMediaDownloadSnapshot(message: message),
            localMessageID: message.id,
            serverMessageID: message.serverMessageID,
            senderUserID: message.senderUserID,
            selectableID: Self.selectableMessageID(for: message),
            direction: message.direction,
            createdAtText: message.createdAt.formatted(date: .omitted, time: .shortened),
            reactions: message.derivedState.reactions,
            isEdited: !message.derivedState.edits.isEmpty,
            copyableText: IMChatMessageRowSnapshot.copyableText(for: message),
            deliveryDisplay: IMChatMessageRowSnapshot.deliveryDisplay(
                for: message,
                deliveryOverrideText: deliveryOverrideText(for: message)
            ),
            canRetry: isRetryableFailure(message),
            canCancel: message.canCancelQueuedSend,
            canReply: message.canReply,
            canRecall: message.canRecall,
            canEdit: message.canEdit,
            canReact: message.canReact,
            deliveryOverrideText: deliveryOverrideText(for: message)
        )
    }

    func pendingMessageRowSnapshot(
        for message: IMPendingConversationMessage,
        isRetryableFailure: (IMPendingConversationMessage) -> Bool
    ) -> IMChatPendingMessageRowSnapshot {
        IMChatPendingMessageRowSnapshot(
            localMessageID: message.id,
            senderUserID: message.senderUserID,
            text: message.text,
            createdAtText: message.createdAt.formatted(date: .omitted, time: .shortened),
            deliveryDisplay: IMChatMessageDeliverySnapshot.deliveryDisplay(for: message.deliveryState),
            canCancel: message.canCancelQueuedSend,
            canRetry: isRetryableFailure(message)
        )
    }

    var contextSnapshot: IMChatContextSnapshot {
        let kind = conversation?.kind ?? .group
        let memberCount = conversation?.memberCount ?? conversation?.memberUserIDs.count ?? 0
        return IMChatContextSnapshot(
            kind: kind,
            memberCount: memberCount,
            currentGroupRole: currentGroupRole,
            isPinned: conversation?.isPinned == true,
            isMuted: conversation?.isMuted == true,
            isMuteAll: conversation?.muteAll == true,
            notice: conversation?.notice,
            directMessagingStatusMessage: directMessagingStatusMessage,
            showsLoadingIndicator: isLoadingMembers || isLoadingMessages
        )
    }

    static func selectableMessageID(for message: IMConversationMessage) -> String? {
        if UUID(uuidString: message.serverMessageID) != nil {
            return message.serverMessageID
        }
        return UUID(uuidString: message.id) == nil ? nil : message.id
    }

    static func noticeDisplayText(for notice: IMTimelineNotice) -> String {
        switch notice.noticeKind {
        case "member_added":
            return "成员已加入会话"
        case "member_removed":
            return "成员已离开会话"
        case "member_role_updated":
            return "成员角色已更新"
        case "metadata_updated":
            return "会话信息已更新"
        case "direct_peer_updated":
            return "联系人状态已更新"
        case "conversation_visibility_changed":
            return "会话可见性已更新"
        case "conversation_settings_changed":
            return "会话设置已更新"
        case "invite_changed":
            return "邀请链接已更新"
        default:
            return notice.fallbackText
        }
    }
}

struct IMChatPageSnapshotBuilder {
    func build(
        conversationID: String,
        generation: UInt64,
        conversations: [IMConversation],
        queueSummary: IMConversationQueueSummary,
        receiptSummary: IMConversationReceiptSummaryResponseBody?,
        isLoadingMessages: Bool,
        isLoadingMembers: Bool,
        currentUserID: UUID?,
        blockedUserIDs: Set<UUID>,
        isRetryableMessageFailure: (IMConversationMessage) -> Bool = { _ in false },
        isRetryablePendingMessageFailure: (IMPendingConversationMessage) -> Bool = { _ in false }
    ) -> IMChatPageSnapshot {
        let conversation = conversations.first { $0.id == conversationID }
        let messages = conversation?.messages ?? []
        let timelineItems = conversation?.timelineItems ?? []
        return IMChatPageSnapshot(
            conversationID: conversationID,
            generation: generation,
            conversation: conversation,
            messages: messages,
            timelineItems: timelineItems,
            timelineRows: timelineRows(
                from: timelineItems,
                messages: messages,
                conversationKind: conversation?.kind,
                receiptSummary: receiptSummary,
                isRetryableMessageFailure: isRetryableMessageFailure,
                isRetryablePendingMessageFailure: isRetryablePendingMessageFailure
            ),
            metrics: IMChatPageMetricsSnapshot(
                pendingMessageCount: conversation?.pendingMessages.count ?? 0,
                messageCount: messages.count,
                timelineItemCount: timelineItems.count
            ),
            hasMoreHistory: conversation?.hasMoreHistory == true,
            queueSummary: queueSummary,
            receiptSummary: receiptSummary,
            isLoadingMessages: isLoadingMessages,
            isLoadingMembers: isLoadingMembers,
            currentUserID: currentUserID,
            blockedUserIDs: blockedUserIDs
        )
    }

    private func timelineRows(
        from timelineItems: [IMConversationTimelineItem],
        messages: [IMConversationMessage],
        conversationKind: IMConversationKind?,
        receiptSummary: IMConversationReceiptSummaryResponseBody?,
        isRetryableMessageFailure: (IMConversationMessage) -> Bool,
        isRetryablePendingMessageFailure: (IMPendingConversationMessage) -> Bool
    ) -> [IMChatTimelineRowSnapshot] {
        timelineItems.map { item in
            switch item {
            case .message(let message):
                return .message(
                    IMChatMessageRowSnapshot(
                        content: IMChatMessageContentSnapshot(message: message),
                        replyReference: message.resolvedReplyReference(in: messages),
                        replyTarget: IMChatReplyTargetSnapshot(message: message),
                        editingTarget: IMChatEditingTargetSnapshot(message: message),
                        mediaDownload: IMChatMediaDownloadSnapshot(message: message),
                        localMessageID: message.id,
                        serverMessageID: message.serverMessageID,
                        senderUserID: message.senderUserID,
                        selectableID: IMChatPageSnapshot.selectableMessageID(for: message),
                        direction: message.direction,
                        createdAtText: message.createdAt.formatted(date: .omitted, time: .shortened),
                        reactions: message.derivedState.reactions,
                        isEdited: !message.derivedState.edits.isEmpty,
                        copyableText: IMChatMessageRowSnapshot.copyableText(for: message),
                        deliveryDisplay: IMChatMessageRowSnapshot.deliveryDisplay(
                            for: message,
                            deliveryOverrideText: IMChatPageSnapshot.deliveryOverrideText(
                                for: message,
                                conversationKind: conversationKind,
                                receiptSummary: receiptSummary
                            )
                        ),
                        canRetry: isRetryableMessageFailure(message),
                        canCancel: message.canCancelQueuedSend,
                        canReply: message.canReply,
                        canRecall: message.canRecall,
                        canEdit: message.canEdit,
                        canReact: message.canReact,
                        deliveryOverrideText: IMChatPageSnapshot.deliveryOverrideText(
                            for: message,
                            conversationKind: conversationKind,
                            receiptSummary: receiptSummary
                        )
                    )
                )
            case .notice(let notice):
                return .notice(
                    IMChatNoticeRowSnapshot(
                        id: item.id,
                        noticeKind: notice.noticeKind,
                        displayText: IMChatPageSnapshot.noticeDisplayText(for: notice)
                    )
                )
            case .pendingMessage(let message):
                return .pendingMessage(
                    IMChatPendingMessageRowSnapshot(
                        localMessageID: message.id,
                        senderUserID: message.senderUserID,
                        text: message.text,
                        createdAtText: message.createdAt.formatted(date: .omitted, time: .shortened),
                        deliveryDisplay: IMChatMessageDeliverySnapshot.deliveryDisplay(for: message.deliveryState),
                        canCancel: message.canCancelQueuedSend,
                        canRetry: isRetryablePendingMessageFailure(message)
                    )
                )
            }
        }
    }
}

@MainActor
extension IMConversationStore {
    func chatPageSnapshot(
        for conversationID: String,
        currentUserID: UUID?,
        blockedUserIDs: Set<UUID>
    ) -> IMChatPageSnapshot {
        IMChatPageSnapshotBuilder().build(
            conversationID: conversationID,
            generation: conversationMutationGeneration,
            conversations: conversations,
            queueSummary: queueSummary(for: conversationID),
            receiptSummary: receiptSummary(for: conversationID),
            isLoadingMessages: isLoadingMessages,
            isLoadingMembers: isLoadingMembers,
            currentUserID: currentUserID,
            blockedUserIDs: blockedUserIDs,
            isRetryableMessageFailure: { message in
                self.isRetryableFailure(message)
            },
            isRetryablePendingMessageFailure: { message in
                self.isRetryableFailure(message)
            }
        )
    }
}

enum IMChatTimelineRowSnapshot: Identifiable, Equatable {
    case message(IMChatMessageRowSnapshot)
    case notice(IMChatNoticeRowSnapshot)
    case pendingMessage(IMChatPendingMessageRowSnapshot)

    var id: String {
        switch self {
        case .message(let row):
            return "message:\(row.localMessageID)"
        case .notice(let row):
            return row.id
        case .pendingMessage(let row):
            return "pendingMessage:\(row.localMessageID)"
        }
    }
}

struct IMChatPageMetricsSnapshot: Equatable {
    let pendingMessageCount: Int
    let messageCount: Int
    let timelineItemCount: Int
}

struct IMChatDirectPeerSnapshot: Equatable {
    let id: UUID
    let email: String
    let avatarPreset: UserAvatarPreset?

    init(peer: IMDirectPeer) {
        self.id = peer.id
        self.email = peer.email
        self.avatarPreset = peer.avatarPreset
    }
}

struct IMChatMessageContentSnapshot: Equatable {
    enum Body: Equatable {
        case richText(body: IMRichTextContent, fallbackText: String)
        case reply(referenceMessageID: String, body: IMRichTextContent, fallbackText: String)
        case image(asset: IMMediaAsset, subtitle: String)
        case audio(asset: IMMediaAsset, subtitle: String)
        case file(asset: IMMediaAsset, subtitle: String)
        case recalled(text: String)
    }

    let body: Body
    let mediaAsset: IMMediaAsset?
    let replyReferenceMessageID: String?

    init(message: IMConversationMessage) {
        let presentation = MessagePresentation(aggregate: message.aggregate)
        switch message.aggregate.primaryContent {
        case .richText(let body):
            self.body = .richText(
                body: body,
                fallbackText: presentation.textValue ?? message.text
            )
            self.mediaAsset = nil
            self.replyReferenceMessageID = nil
        case .reply(let reference, let body):
            self.body = .reply(
                referenceMessageID: reference.messageID,
                body: body,
                fallbackText: presentation.textValue ?? message.text
            )
            self.mediaAsset = nil
            self.replyReferenceMessageID = reference.messageID
        case .image(let asset):
            self.body = .image(asset: asset, subtitle: Self.mediaSubtitle(for: asset))
            self.mediaAsset = asset
            self.replyReferenceMessageID = nil
        case .audio(let asset):
            self.body = .audio(asset: asset, subtitle: Self.mediaSubtitle(for: asset))
            self.mediaAsset = asset
            self.replyReferenceMessageID = nil
        case .file(let asset):
            self.body = .file(asset: asset, subtitle: Self.mediaSubtitle(for: asset))
            self.mediaAsset = asset
            self.replyReferenceMessageID = nil
        case nil:
            self.body = .recalled(
                text: message.direction == .outgoing ? "你撤回了一条消息" : "对方撤回了一条消息"
            )
            self.mediaAsset = nil
            self.replyReferenceMessageID = nil
        }
    }

    private static func mediaSubtitle(for asset: IMMediaAsset) -> String {
        var parts: [String] = []
        if asset.byteSize > 0 {
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            parts.append(formatter.string(fromByteCount: asset.byteSize))
        }
        if let width = asset.width, let height = asset.height {
            parts.append("\(width)×\(height)")
        }
        if let durationMillis = asset.durationMillis, durationMillis > 0 {
            parts.append(formatDuration(durationMillis))
        }
        return parts.joined(separator: " · ")
    }

    private static func formatDuration(_ durationMillis: Int) -> String {
        let totalSeconds = max(0, durationMillis / 1000)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

struct IMChatMessageDeliverySnapshot: Equatable {
    enum Tone: Equatable {
        case secondary
        case blue
        case orange
        case red
    }

    let icon: String
    let text: String
    let tone: Tone

    static func deliveryDisplay(for state: IMMessageDeliveryState) -> IMChatMessageDeliverySnapshot {
        switch state {
        case .preparing(let message):
            return IMChatMessageDeliverySnapshot(icon: "clock", text: shortStatus("准备中", detail: message), tone: .secondary)
        case .uploading(let message):
            return IMChatMessageDeliverySnapshot(icon: "icloud.and.arrow.up", text: shortStatus("上传中", detail: message), tone: .blue)
        case .uploaded:
            return IMChatMessageDeliverySnapshot(icon: "icloud.and.arrow.up.fill", text: "上传完成", tone: .blue)
        case .queued(let message):
            return IMChatMessageDeliverySnapshot(icon: "clock.badge.exclamationmark", text: shortStatus("待发送", detail: message), tone: .orange)
        case .sending:
            return IMChatMessageDeliverySnapshot(icon: "paperplane", text: "发送中", tone: .secondary)
        case .sent:
            return IMChatMessageDeliverySnapshot(icon: "checkmark", text: "已发送", tone: .secondary)
        case .received:
            return IMChatMessageDeliverySnapshot(icon: "checkmark.circle", text: "已送达", tone: .secondary)
        case .unknown(let message):
            return IMChatMessageDeliverySnapshot(icon: "questionmark.circle", text: shortStatus("未确认", detail: message), tone: .orange)
        case .failed(let message):
            return IMChatMessageDeliverySnapshot(icon: "exclamationmark.circle.fill", text: shortStatus("失败", detail: message), tone: .red)
        }
    }

    private static func shortStatus(_ prefix: String, detail: String) -> String {
        let trimmedDetail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDetail.isEmpty else {
            return prefix
        }
        return "\(prefix): \(trimmedDetail)"
    }
}

struct IMChatReplyTargetSnapshot: Equatable {
    let localMessageID: String
    let reference: IMReplyReference

    init?(message: IMConversationMessage) {
        guard message.canReply else {
            return nil
        }
        self.localMessageID = message.id
        self.reference = IMReplyReference(
            messageID: message.serverMessageID,
            senderUserID: message.senderUserID,
            previewText: Self.previewText(for: message)
        )
    }

    private static func previewText(for message: IMConversationMessage) -> String {
        if message.derivedState.isRecalled {
            return "原消息已撤回"
        }

        let preview = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return preview.isEmpty ? "原消息暂不可用" : preview
    }
}

struct IMChatEditingTargetSnapshot: Equatable {
    let localMessageID: String
    let serverMessageID: String
    let previewText: String
    let initialComposerText: String

    init?(message: IMConversationMessage) {
        guard message.canEdit else {
            return nil
        }
        let text = MessagePresentation(aggregate: message.aggregate).textValue ?? ""
        self.localMessageID = message.id
        self.serverMessageID = message.serverMessageID
        self.previewText = text.isEmpty ? "消息内容不可编辑" : text
        self.initialComposerText = text
    }
}

struct IMChatMediaDownloadSnapshot: Equatable {
    let localMessageID: String
    let asset: IMMediaAsset
    let localDownloadState: IMMessageLocalDownloadState?

    init?(message: IMConversationMessage) {
        guard let asset = message.mediaAsset else {
            return nil
        }
        self.localMessageID = message.id
        self.asset = asset
        self.localDownloadState = message.localDownloadState
    }
}

struct IMChatMessageRowSnapshot: Equatable {
    let content: IMChatMessageContentSnapshot
    let replyReference: IMReplyReferenceResolution?
    let replyTarget: IMChatReplyTargetSnapshot?
    let editingTarget: IMChatEditingTargetSnapshot?
    let mediaDownload: IMChatMediaDownloadSnapshot?
    let localMessageID: String
    let serverMessageID: String
    let senderUserID: UUID
    let selectableID: String?
    let direction: IMMessageDirection
    let createdAtText: String
    let reactions: [MessageReaction]
    let isEdited: Bool
    let copyableText: String?
    let deliveryDisplay: IMChatMessageDeliverySnapshot?
    let canRetry: Bool
    let canCancel: Bool
    let canReply: Bool
    let canRecall: Bool
    let canEdit: Bool
    let canReact: Bool
    let deliveryOverrideText: String?

    static func copyableText(for message: IMConversationMessage) -> String? {
        let text = MessagePresentation(aggregate: message.aggregate).textValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let text, !text.isEmpty else {
            return nil
        }
        return text
    }

    static func deliveryDisplay(
        for message: IMConversationMessage,
        deliveryOverrideText: String?
    ) -> IMChatMessageDeliverySnapshot? {
        guard message.direction == .outgoing else {
            return nil
        }

        if let deliveryOverrideText {
            return IMChatMessageDeliverySnapshot(
                icon: "checkmark.circle",
                text: deliveryOverrideText,
                tone: .secondary
            )
        }

        return IMChatMessageDeliverySnapshot.deliveryDisplay(for: message.deliveryState)
    }
}

struct IMChatNoticeRowSnapshot: Equatable {
    let id: String
    let noticeKind: String
    let displayText: String
}

struct IMChatPendingMessageRowSnapshot: Equatable {
    let localMessageID: String
    let senderUserID: UUID
    let text: String
    let createdAtText: String
    let deliveryDisplay: IMChatMessageDeliverySnapshot
    let canCancel: Bool
    let canRetry: Bool
}

struct IMChatContextSnapshot: Equatable {
    let kind: IMConversationKind
    let memberCount: Int
    let currentGroupRole: IMConversationMemberRole?
    let isPinned: Bool
    let isMuted: Bool
    let isMuteAll: Bool
    let notice: String?
    let directMessagingStatusMessage: String?
    let showsLoadingIndicator: Bool

    var kindText: String {
        switch kind {
        case .direct:
            return "私聊"
        case .group:
            return "群聊"
        }
    }

    var kindIcon: String {
        switch kind {
        case .direct:
            return "person.2"
        case .group:
            return "person.3"
        }
    }

    var shouldShow: Bool {
        kind == .group
            || notice?.isEmpty == false
            || directMessagingStatusMessage != nil
            || isPinned
            || isMuted
            || isMuteAll
            || showsLoadingIndicator
    }
}
