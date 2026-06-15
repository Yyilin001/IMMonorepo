import Foundation
import IMClientKit

/// Immutable projection for one conversation detail page.
///
/// The detail view renders this value instead of retaining raw conversation,
/// message, member, receipt, or queue models across SwiftUI updates.
struct IMChatPageSnapshot: Equatable, Sendable {
    let conversationID: String
    let generation: UInt64
    let timelineRows: [IMChatTimelineRowSnapshot]
    let metrics: IMChatPageMetricsSnapshot
    let hasMoreHistory: Bool
    let metadata: IMChatConversationMetadataSnapshot
    let contextSnapshot: IMChatContextSnapshot
    let queueSummary: IMConversationQueueSummary
    let receiptSummary: IMChatReceiptSummarySnapshot?
    let statusMessage: String?
    let isLoadingMessages: Bool
    let isLoadingMembers: Bool
    let currentUserID: UUID?
    let currentGroupRole: IMConversationMemberRole?
    let currentMemberNickname: String?
    let directPeerSnapshot: IMChatDirectPeerSnapshot?
    let isDirectPeerBlocked: Bool
    let canSendMessages: Bool

    var composerDisabledReason: String? {
        if isDirectPeerBlocked {
            return "已屏蔽对方"
        }
        guard contextSnapshot.kind == .group,
              contextSnapshot.isMuteAll,
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

    var latestItemID: String? {
        timelineRows.last?.id
    }

    /// Fallback anchor used before row geometry has produced a measured visible row.
    var historyLoadAnchor: IMChatScrollAnchorSnapshot? {
        timelineRows.first.map { row in
            IMChatScrollAnchorSnapshot(itemID: row.id, offsetFromTop: 0)
        }
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

    static func empty(
        conversationID: String,
        generation: UInt64 = 0
    ) -> IMChatPageSnapshot {
        IMChatPageSnapshotBuilder().build(
            conversationID: conversationID,
            generation: generation,
            conversations: [],
            queueSummary: IMConversationQueueSummary(
                queuedCount: 0,
                sendingCount: 0,
                retryableIssueCount: 0
            ),
            receiptSummary: nil,
            isLoadingMessages: false,
            isLoadingMembers: false,
            currentUserID: nil,
            blockedUserIDs: []
        )
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

    static func deliveryOverrideText(
        for message: IMConversationMessage,
        conversationKind: IMConversationKind?,
        receiptSummary: IMChatReceiptSummarySnapshot?
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

/// Scroll position of a timeline row relative to the chat viewport top edge.
struct IMChatScrollAnchorSnapshot: Equatable, Sendable {
    let itemID: String
    let offsetFromTop: Double
}

/// Target content offset calculated after older history changes timeline height.
struct IMChatHistoryScrollAnchorRestoration: Equatable, Sendable {
    let targetContentOffsetY: Double
}

/// Converts a saved row offset and a new measured row offset into a scroll target.
///
/// When older messages are inserted above the anchor row, the measured offset grows
/// by the inserted height. Adding that delta to the current content offset keeps the
/// same row visually pinned in the viewport.
struct IMChatHistoryScrollAnchorRestorer: Equatable, Sendable {
    func restoration(
        anchor: IMChatScrollAnchorSnapshot,
        measuredOffsetFromTop: Double,
        currentContentOffsetY: Double
    ) -> IMChatHistoryScrollAnchorRestoration {
        let adjustment = measuredOffsetFromTop - anchor.offsetFromTop
        return IMChatHistoryScrollAnchorRestoration(
            targetContentOffsetY: max(0, currentContentOffsetY + adjustment)
        )
    }
}

/// Read and delivery projection used by outgoing message rows.
struct IMChatReceiptSummarySnapshot: Equatable, Sendable {
    let deliveredThroughSequence: UInt64
    let readThroughSequence: UInt64
    let readableMemberCount: Int

    init(
        deliveredThroughSequence: UInt64,
        readThroughSequence: UInt64,
        readableMemberCount: Int
    ) {
        self.deliveredThroughSequence = deliveredThroughSequence
        self.readThroughSequence = readThroughSequence
        self.readableMemberCount = readableMemberCount
    }

    init(_ receiptSummary: IMConversationReceiptSummaryResponseBody) {
        self.init(
            deliveredThroughSequence: receiptSummary.deliveredThroughSequence,
            readThroughSequence: receiptSummary.readThroughSequence,
            readableMemberCount: receiptSummary.readableMemberCount
        )
    }
}

/// Projects raw conversation state into a chat-page snapshot.
///
/// This is the only layer in the detail page path that inspects messages, members,
/// pending queue state, and receipt summaries directly.
struct IMChatPageSnapshotBuilder {
    func build(
        conversationID: String,
        generation: UInt64,
        conversations: [IMConversation],
        queueSummary: IMConversationQueueSummary,
        receiptSummary: IMConversationReceiptSummaryResponseBody?,
        statusMessage: String? = nil,
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
        let currentMember = currentUserID.flatMap { currentUserID in
            conversation?.members.first { $0.id == currentUserID }
        }
        let currentGroupRole = currentMember?.role
        let directPeer = conversation?.kind == .direct ? conversation?.directPeer : nil
        let receiptSummarySnapshot = receiptSummary.map(IMChatReceiptSummarySnapshot.init)
        let isDirectPeerBlocked = directPeer.map { blockedUserIDs.contains($0.id) } ?? false
        let canSendMessages = Self.canSendMessages(
            conversation: conversation,
            currentGroupRole: currentGroupRole,
            isDirectPeerBlocked: isDirectPeerBlocked
        )
        let contextSnapshot = Self.contextSnapshot(
            conversation: conversation,
            currentGroupRole: currentGroupRole,
            isLoadingMessages: isLoadingMessages,
            isLoadingMembers: isLoadingMembers
        )
        return IMChatPageSnapshot(
            conversationID: conversationID,
            generation: generation,
            timelineRows: timelineRows(
                from: timelineItems,
                messages: messages,
                conversationKind: conversation?.kind,
                receiptSummary: receiptSummarySnapshot,
                isRetryableMessageFailure: isRetryableMessageFailure,
                isRetryablePendingMessageFailure: isRetryablePendingMessageFailure
            ),
            metrics: IMChatPageMetricsSnapshot(
                pendingMessageCount: conversation?.pendingMessages.count ?? 0,
                messageCount: messages.count,
                timelineItemCount: timelineItems.count
            ),
            hasMoreHistory: conversation?.hasMoreHistory == true,
            metadata: IMChatConversationMetadataSnapshot(
                conversationID: conversationID,
                title: conversation?.title ?? "会话",
                notice: conversation?.notice ?? "",
                avatarPreset: conversation?.avatarPreset ?? .ocean,
                muteAll: conversation?.muteAll == true
            ),
            contextSnapshot: contextSnapshot,
            queueSummary: queueSummary,
            receiptSummary: receiptSummarySnapshot,
            statusMessage: statusMessage,
            isLoadingMessages: isLoadingMessages,
            isLoadingMembers: isLoadingMembers,
            currentUserID: currentUserID,
            currentGroupRole: currentGroupRole,
            currentMemberNickname: currentMember?.memberNickname,
            directPeerSnapshot: directPeer.map(IMChatDirectPeerSnapshot.init),
            isDirectPeerBlocked: isDirectPeerBlocked,
            canSendMessages: canSendMessages
        )
    }

    private static func canSendMessages(
        conversation: IMConversation?,
        currentGroupRole: IMConversationMemberRole?,
        isDirectPeerBlocked: Bool
    ) -> Bool {
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

    private static func contextSnapshot(
        conversation: IMConversation?,
        currentGroupRole: IMConversationMemberRole?,
        isLoadingMessages: Bool,
        isLoadingMembers: Bool
    ) -> IMChatContextSnapshot {
        IMChatContextSnapshot(
            kind: conversation?.kind ?? .group,
            memberCount: conversation?.memberCount ?? conversation?.memberUserIDs.count ?? 0,
            currentGroupRole: currentGroupRole,
            isPinned: conversation?.isPinned == true,
            isMuted: conversation?.isMuted == true,
            isMuteAll: conversation?.muteAll == true,
            notice: conversation?.notice,
            directMessagingStatusMessage: conversation?.directMessagingStatusMessage,
            showsLoadingIndicator: isLoadingMembers || isLoadingMessages
        )
    }

    private func timelineRows(
        from timelineItems: [IMConversationTimelineItem],
        messages: [IMConversationMessage],
        conversationKind: IMConversationKind?,
        receiptSummary: IMChatReceiptSummarySnapshot?,
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
            statusMessage: statusMessage,
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

/// Heterogeneous timeline row rendered by the chat detail list.
enum IMChatTimelineRowSnapshot: Identifiable, Equatable, Sendable {
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

/// Lightweight counters used for logging and snapshot regression tests.
struct IMChatPageMetricsSnapshot: Equatable, Sendable {
    let pendingMessageCount: Int
    let messageCount: Int
    let timelineItemCount: Int
}

/// Header-level conversation metadata for the detail page.
struct IMChatConversationMetadataSnapshot: Equatable, Sendable {
    let conversationID: String
    let title: String
    let notice: String
    let avatarPreset: IMConversationAvatarPreset
    let muteAll: Bool
}

/// Direct-peer fields needed by the detail page after projection.
struct IMChatDirectPeerSnapshot: Equatable, Sendable {
    let id: UUID
    let email: String
    let avatarPreset: UserAvatarPreset?

    init(peer: IMDirectPeer) {
        self.id = peer.id
        self.email = peer.email
        self.avatarPreset = peer.avatarPreset
    }
}

/// Renderable message content extracted from the aggregate message model.
struct IMChatMessageContentSnapshot: Equatable, Sendable {
    enum Body: Equatable, Sendable {
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

struct IMChatMessageDeliverySnapshot: Equatable, Sendable {
    enum Tone: Equatable, Sendable {
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

struct IMChatReplyTargetSnapshot: Equatable, Sendable {
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

struct IMChatEditingTargetSnapshot: Equatable, Sendable {
    let localMessageID: String
    let serverMessageID: String
    let previewText: String
    let initialComposerText: String

    init(
        localMessageID: String,
        serverMessageID: String,
        previewText: String,
        initialComposerText: String
    ) {
        self.localMessageID = localMessageID
        self.serverMessageID = serverMessageID
        self.previewText = previewText
        self.initialComposerText = initialComposerText
    }

    init?(message: IMConversationMessage) {
        guard message.canEdit else {
            return nil
        }
        let text = MessagePresentation(aggregate: message.aggregate).textValue ?? ""
        self.init(
            localMessageID: message.id,
            serverMessageID: message.serverMessageID,
            previewText: text.isEmpty ? "消息内容不可编辑" : text,
            initialComposerText: text
        )
    }
}

/// Value-only composer presentation state for send and edit modes.
///
/// The composer renders this snapshot while user input remains local `@State`;
/// domain restrictions such as mute-all or blocked peer are already projected.
struct IMConversationComposerSnapshot: Equatable, Sendable {
    enum ActionKind: Equatable, Sendable {
        case send
        case saveEdit
    }

    let text: String
    let canSendMessages: Bool
    let disabledReason: String?
    let replyTarget: IMChatReplyTargetSnapshot?
    let editingTarget: IMChatEditingTargetSnapshot?

    var actionKind: ActionKind {
        editingTarget == nil ? .send : .saveEdit
    }

    var placeholder: String {
        disabledReason ?? "输入消息"
    }

    var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isSendEnabled: Bool {
        canSendMessages && !trimmedText.isEmpty
    }

    var shouldShowTopPadding: Bool {
        replyTarget == nil && editingTarget == nil
    }

    var shouldShowTextFieldTopPadding: Bool {
        shouldShowTopPadding && disabledReason == nil
    }

    var actionSystemImage: String {
        switch actionKind {
        case .send:
            return "paperplane.fill"
        case .saveEdit:
            return "square.and.arrow.down.fill"
        }
    }

    var actionAccessibilityLabel: String {
        switch actionKind {
        case .send:
            return "发送消息"
        case .saveEdit:
            return "保存编辑"
        }
    }
}

/// Media download state attached to a specific rendered message row.
struct IMChatMediaDownloadSnapshot: Equatable, Sendable {
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

/// Stable presentation row for a persisted message.
struct IMChatMessageRowSnapshot: Equatable, Sendable {
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

/// Timeline notice row with display text resolved before rendering.
struct IMChatNoticeRowSnapshot: Equatable, Sendable {
    let id: String
    let noticeKind: String
    let displayText: String
}

/// Timeline row for a locally queued or sending message.
struct IMChatPendingMessageRowSnapshot: Equatable, Sendable {
    let localMessageID: String
    let senderUserID: UUID
    let text: String
    let createdAtText: String
    let deliveryDisplay: IMChatMessageDeliverySnapshot
    let canCancel: Bool
    let canRetry: Bool
}

/// Conversation context strip and capability state for the detail page.
struct IMChatContextSnapshot: Equatable, Sendable {
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
