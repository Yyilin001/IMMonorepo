import Foundation
@testable import IMClientKit
import Testing
@testable import IMApp

struct IMChatPageSnapshotTests {
    private let currentUserID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let peerUserID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    @Test func composerSnapshotProjectsSendAndEditPresentationState() {
        let sendSnapshot = IMConversationComposerSnapshot(
            text: "  hello  ",
            canSendMessages: true,
            disabledReason: nil,
            replyTarget: nil,
            editingTarget: nil
        )

        #expect(sendSnapshot.actionKind == .send)
        #expect(sendSnapshot.placeholder == "输入消息")
        #expect(sendSnapshot.trimmedText == "hello")
        #expect(sendSnapshot.isSendEnabled)
        #expect(sendSnapshot.shouldShowTopPadding)
        #expect(sendSnapshot.shouldShowTextFieldTopPadding)
        #expect(sendSnapshot.actionSystemImage == "paperplane.fill")
        #expect(sendSnapshot.actionAccessibilityLabel == "发送消息")

        let editingTarget = IMChatEditingTargetSnapshot(
            localMessageID: "local-edit",
            serverMessageID: "server-edit",
            previewText: "before",
            initialComposerText: "before"
        )
        let editSnapshot = IMConversationComposerSnapshot(
            text: "updated",
            canSendMessages: true,
            disabledReason: "全员禁言中",
            replyTarget: nil,
            editingTarget: editingTarget
        )

        #expect(editSnapshot.actionKind == IMConversationComposerSnapshot.ActionKind.saveEdit)
        #expect(editSnapshot.placeholder == "全员禁言中")
        #expect(editSnapshot.isSendEnabled)
        #expect(!editSnapshot.shouldShowTopPadding)
        #expect(!editSnapshot.shouldShowTextFieldTopPadding)
        #expect(editSnapshot.actionSystemImage == "square.and.arrow.down.fill")
        #expect(editSnapshot.actionAccessibilityLabel == "保存编辑")
    }

    @Test func composerSnapshotDisablesWhitespaceOrBlockedInput() {
        let blankSnapshot = IMConversationComposerSnapshot(
            text: "   ",
            canSendMessages: true,
            disabledReason: nil,
            replyTarget: nil,
            editingTarget: nil
        )
        #expect(!blankSnapshot.isSendEnabled)

        let disabledSnapshot = IMConversationComposerSnapshot(
            text: "hello",
            canSendMessages: false,
            disabledReason: "已屏蔽对方",
            replyTarget: nil,
            editingTarget: nil
        )
        #expect(disabledSnapshot.placeholder == "已屏蔽对方")
        #expect(!disabledSnapshot.isSendEnabled)
    }

    @Test func historyScrollAnchorRestorerPreservesMeasuredOffset() {
        let anchor = IMChatScrollAnchorSnapshot(
            itemID: "message:anchor",
            offsetFromTop: 32
        )

        let restoration = IMChatHistoryScrollAnchorRestorer().restoration(
            anchor: anchor,
            measuredOffsetFromTop: 180,
            currentContentOffsetY: 420
        )

        #expect(restoration.targetContentOffsetY == 568)
    }

    @Test func historyScrollAnchorRestorerClampsNegativeTargetOffset() {
        let anchor = IMChatScrollAnchorSnapshot(
            itemID: "message:anchor",
            offsetFromTop: 160
        )

        let restoration = IMChatHistoryScrollAnchorRestorer().restoration(
            anchor: anchor,
            measuredOffsetFromTop: 20,
            currentContentOffsetY: 80
        )

        #expect(restoration.targetContentOffsetY == 0)
    }

    @Test func builderProjectsTimelineAndLatestOutgoingAnchor() throws {
        let conversationID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        let sent = try makeMessage(
            id: "m1",
            conversationID: conversationID,
            senderUserID: currentUserID,
            serverSequence: 1,
            timelineSequence: 1,
            direction: .outgoing,
            deliveryState: .sent
        )
        let pending = IMPendingConversationMessage(
            localMessageID: "p1",
            clientMessageID: "p1",
            conversationID: conversationID,
            senderUserID: currentUserID,
            content: testMessageContent(kind: "rich_text", body: ["text": "pending"]),
            createdAt: Date(timeIntervalSince1970: 20),
            deliveryState: .queued(message: "等待发送")
        )
        let conversation = makeConversation(
            id: conversationID,
            kind: .direct,
            messages: [sent],
            pendingMessages: [pending]
        )
        let queueSummary = IMConversationQueueSummary(queuedCount: 1, sendingCount: 0, retryableIssueCount: 0)

        let snapshot = IMChatPageSnapshotBuilder().build(
            conversationID: conversationID,
            generation: 42,
            conversations: [conversation],
            queueSummary: queueSummary,
            receiptSummary: nil,
            statusMessage: "聊天同步提示",
            isLoadingMessages: false,
            isLoadingMembers: false,
            currentUserID: currentUserID,
            blockedUserIDs: []
        )

        #expect(snapshot.generation == 42)
        #expect(snapshot.conversationID == conversationID)
        #expect(snapshot.metadata.conversationID == conversationID)
        #expect(snapshot.metadata.title == "Conversation")
        #expect(snapshot.metadata.notice.isEmpty)
        #expect(snapshot.metadata.avatarPreset == .ocean)
        #expect(!snapshot.metadata.muteAll)
        #expect(snapshot.timelineRows.map(\.id) == ["message:m1", "pendingMessage:p1"])
        #expect(snapshot.metrics.pendingMessageCount == 1)
        #expect(snapshot.metrics.messageCount == 1)
        #expect(snapshot.metrics.timelineItemCount == 2)
        #expect(!snapshot.hasMoreHistory)
        #expect(snapshot.latestItemID == "pendingMessage:p1")
        #expect(snapshot.historyLoadAnchor?.itemID == "message:m1")
        #expect(snapshot.historyLoadAnchor?.offsetFromTop == 0)
        #expect(snapshot.latestTimelineItemIsCurrentUserOutgoing)
        #expect(snapshot.queueSummary == queueSummary)
        #expect(snapshot.statusMessage == "聊天同步提示")
        #expect(!snapshot.shouldShowLoadingState)
    }

    @Test func builderRepresentsMissingLoadingConversation() {
        let snapshot = IMChatPageSnapshotBuilder().build(
            conversationID: "missing",
            generation: 1,
            conversations: [],
            queueSummary: IMConversationQueueSummary(queuedCount: 0, sendingCount: 0, retryableIssueCount: 0),
            receiptSummary: nil,
            isLoadingMessages: true,
            isLoadingMembers: false,
            currentUserID: currentUserID,
            blockedUserIDs: []
        )

        #expect(snapshot.conversationID == "missing")
        #expect(snapshot.metadata.title == "会话")
        #expect(snapshot.metadata.notice.isEmpty)
        #expect(snapshot.metadata.avatarPreset == .ocean)
        #expect(!snapshot.metadata.muteAll)
        #expect(snapshot.timelineRows.isEmpty)
        #expect(snapshot.metrics.pendingMessageCount == 0)
        #expect(snapshot.metrics.messageCount == 0)
        #expect(snapshot.metrics.timelineItemCount == 0)
        #expect(!snapshot.hasMoreHistory)
        #expect(snapshot.latestItemID == nil)
        #expect(snapshot.historyLoadAnchor == nil)
        #expect(snapshot.statusMessage == nil)
        #expect(snapshot.shouldShowLoadingState)
        #expect(!snapshot.latestTimelineItemIsCurrentUserOutgoing)
    }

    @Test func chatPageSnapshotDoesNotStoreRawConversationTimelineModels() throws {
        let conversationID = "abababab-abab-abab-abab-abababababab"
        let message = try makeMessage(
            id: "pure-row",
            conversationID: conversationID,
            senderUserID: currentUserID,
            serverSequence: 1,
            timelineSequence: 1,
            direction: .outgoing,
            deliveryState: .sent
        )
        let conversation = makeConversation(
            id: conversationID,
            kind: .direct,
            messages: [message],
            pendingMessages: []
        )

        let snapshot = IMChatPageSnapshotBuilder().build(
            conversationID: conversationID,
            generation: 1,
            conversations: [conversation],
            queueSummary: IMConversationQueueSummary(queuedCount: 0, sendingCount: 0, retryableIssueCount: 0),
            receiptSummary: nil,
            isLoadingMessages: false,
            isLoadingMembers: false,
            currentUserID: currentUserID,
            blockedUserIDs: []
        )

        let storedFieldLabels = Mirror(reflecting: snapshot).children.compactMap(\.label)
        #expect(!storedFieldLabels.contains("conversation"))
        #expect(!storedFieldLabels.contains("messages"))
        #expect(!storedFieldLabels.contains("timelineItems"))
        #expect(snapshot.timelineRows.map(\.id) == ["message:pure-row"])
    }

    @Test func deliveryOverrideUsesReceiptProjection() throws {
        let conversationID = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
        let message = try makeMessage(
            id: "m2",
            conversationID: conversationID,
            senderUserID: currentUserID,
            serverSequence: 10,
            timelineSequence: 10,
            direction: .outgoing,
            deliveryState: .sent
        )
        let conversation = makeConversation(
            id: conversationID,
            kind: .group,
            messages: [message],
            pendingMessages: []
        )
        let receipt = IMConversationReceiptSummaryResponseBody(
            conversationID: UUID(uuidString: conversationID)!,
            deliveredThroughSequence: 10,
            readThroughSequence: 3,
            readableMemberCount: 3
        )

        let snapshot = IMChatPageSnapshotBuilder().build(
            conversationID: conversationID,
            generation: 1,
            conversations: [conversation],
            queueSummary: IMConversationQueueSummary(queuedCount: 0, sendingCount: 0, retryableIssueCount: 0),
            receiptSummary: receipt,
            isLoadingMessages: false,
            isLoadingMembers: false,
            currentUserID: currentUserID,
            blockedUserIDs: []
        )

        guard case .message(let row) = try #require(snapshot.timelineRows.first) else {
            Issue.record("Expected projected message row")
            return
        }
        #expect(row.deliveryOverrideText == "部分已读")
        #expect(row.deliveryDisplay?.text == "部分已读")
    }

    @Test func messageRowSnapshotProjectsStableMessagePresentationFields() throws {
        let conversationID = "cccccccc-cccc-cccc-cccc-cccccccccccc"
        let serverMessageID = "dddddddd-dddd-dddd-dddd-dddddddddddd"
        let message = try makeMessage(
            id: "local-row",
            serverMessageID: serverMessageID,
            conversationID: conversationID,
            senderUserID: currentUserID,
            serverSequence: 5,
            timelineSequence: 5,
            direction: .outgoing,
            deliveryState: .sent
        )
        let conversation = makeConversation(
            id: conversationID,
            kind: .direct,
            messages: [message],
            pendingMessages: []
        )
        let snapshot = IMChatPageSnapshotBuilder().build(
            conversationID: conversationID,
            generation: 1,
            conversations: [conversation],
            queueSummary: IMConversationQueueSummary(queuedCount: 0, sendingCount: 0, retryableIssueCount: 0),
            receiptSummary: nil,
            isLoadingMessages: false,
            isLoadingMembers: false,
            currentUserID: currentUserID,
            blockedUserIDs: [],
            isRetryableMessageFailure: { message in
                message.id == "local-row"
            }
        )

        guard case .message(let row) = try #require(snapshot.timelineRows.first) else {
            Issue.record("Expected projected message row")
            return
        }

        #expect(row.localMessageID == "local-row")
        #expect(row.serverMessageID == serverMessageID)
        #expect(row.senderUserID == currentUserID)
        #expect(row.direction == .outgoing)
        #expect(!row.createdAtText.isEmpty)
        #expect(row.copyableText == "local-row")
        #expect(row.replyTarget?.localMessageID == "local-row")
        #expect(row.replyTarget?.reference.messageID == serverMessageID)
        #expect(row.replyTarget?.reference.previewText == "local-row")
        #expect(row.editingTarget?.localMessageID == "local-row")
        #expect(row.editingTarget?.serverMessageID == serverMessageID)
        #expect(row.editingTarget?.previewText == "local-row")
        #expect(row.editingTarget?.initialComposerText == "local-row")
        #expect(row.selectableID == serverMessageID)
        #expect(row.canRetry)
        #expect(!row.canCancel)
        #expect(row.canReply)
        #expect(row.canEdit)
        #expect(row.canReact)
        #expect(row.deliveryOverrideText == "已发送")
        #expect(row.deliveryDisplay?.text == "已发送")
        #expect(row.deliveryDisplay?.icon == "checkmark.circle")
        #expect(row.deliveryDisplay?.tone == .secondary)
        guard case .richText(_, let fallbackText) = row.content.body else {
            Issue.record("Expected rich text content")
            return
        }
        #expect(fallbackText == "local-row")
    }

    @Test func builderProjectsTimelineRowsForRendering() throws {
        let conversationID = "12121212-1212-1212-1212-121212121212"
        let message = try makeMessage(
            id: "row-message",
            serverMessageID: "34343434-3434-3434-3434-343434343434",
            conversationID: conversationID,
            senderUserID: currentUserID,
            serverSequence: 2,
            timelineSequence: 2,
            direction: .outgoing,
            deliveryState: .sent
        )
        let notice = try IMTimelineNotice(
            id: "notice-1",
            conversationID: conversationID,
            timelineSequence: 3,
            eventType: "conversation.member_added",
            actorUserID: peerUserID,
            targetUserIDs: [currentUserID],
            noticeKind: "member_added",
            fallbackText: "fallback",
            createdAt: Date(timeIntervalSince1970: 3)
        )
        let pending = makePendingMessage(
            id: "row-pending",
            conversationID: conversationID,
            deliveryState: .failed(message: "网络错误")
        )
        let conversation = makeConversation(
            id: conversationID,
            kind: .group,
            messages: [message],
            pendingMessages: [pending],
            notices: [notice],
            hasMoreHistory: true
        )
        let receipt = IMConversationReceiptSummaryResponseBody(
            conversationID: UUID(uuidString: conversationID)!,
            deliveredThroughSequence: 2,
            readThroughSequence: 0,
            readableMemberCount: 2
        )

        let snapshot = IMChatPageSnapshotBuilder().build(
            conversationID: conversationID,
            generation: 1,
            conversations: [conversation],
            queueSummary: IMConversationQueueSummary(queuedCount: 0, sendingCount: 0, retryableIssueCount: 1),
            receiptSummary: receipt,
            isLoadingMessages: false,
            isLoadingMembers: false,
            currentUserID: currentUserID,
            blockedUserIDs: [],
            isRetryableMessageFailure: { $0.id == "row-message" },
            isRetryablePendingMessageFailure: { $0.id == "row-pending" }
        )

        #expect(snapshot.timelineRows.map(\.id) == [
            "message:row-message",
            "notice:notice-1",
            "pendingMessage:row-pending"
        ])
        #expect(snapshot.metrics.pendingMessageCount == 1)
        #expect(snapshot.metrics.messageCount == 1)
        #expect(snapshot.metrics.timelineItemCount == 3)
        #expect(snapshot.hasMoreHistory)

        let messageTimelineRow = try #require(snapshot.timelineRows.first)
        guard case .message(let messageRow) = messageTimelineRow else {
            Issue.record("Expected message row")
            return
        }
        #expect(messageRow.canRetry)
        #expect(messageRow.selectableID == "34343434-3434-3434-3434-343434343434")
        #expect(messageRow.deliveryOverrideText == "已送达")
        #expect(messageRow.deliveryDisplay?.text == "已送达")
        #expect(messageRow.deliveryDisplay?.icon == "checkmark.circle")

        let noticeTimelineRow = try #require(snapshot.timelineRows.dropFirst().first)
        guard case .notice(let noticeRow) = noticeTimelineRow else {
            Issue.record("Expected notice row")
            return
        }
        #expect(noticeRow.noticeKind == "member_added")
        #expect(noticeRow.displayText == "成员已加入会话")

        let pendingTimelineRow = try #require(snapshot.timelineRows.dropFirst(2).first)
        guard case .pendingMessage(let pendingRow) = pendingTimelineRow else {
            Issue.record("Expected pending row")
            return
        }
        #expect(pendingRow.localMessageID == "row-pending")
        #expect(pendingRow.senderUserID == currentUserID)
        #expect(pendingRow.text == "row-pending")
        #expect(!pendingRow.createdAtText.isEmpty)
        #expect(pendingRow.deliveryDisplay.text == "失败: 网络错误")
        #expect(pendingRow.deliveryDisplay.icon == "exclamationmark.circle.fill")
        #expect(pendingRow.deliveryDisplay.tone == .red)
        #expect(pendingRow.canRetry)
        #expect(!pendingRow.canCancel)
    }

    @Test func directBlockedPeerProjectsComposerRestriction() {
        let conversationID = "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"
        let conversation = makeConversation(
            id: conversationID,
            kind: .direct,
            directPeer: IMDirectPeer(id: peerUserID, email: "peer@example.com", avatarPreset: .forest),
            messages: [],
            pendingMessages: []
        )

        let snapshot = IMChatPageSnapshotBuilder().build(
            conversationID: conversationID,
            generation: 1,
            conversations: [conversation],
            queueSummary: IMConversationQueueSummary(queuedCount: 0, sendingCount: 0, retryableIssueCount: 0),
            receiptSummary: nil,
            isLoadingMessages: false,
            isLoadingMembers: false,
            currentUserID: currentUserID,
            blockedUserIDs: [peerUserID]
        )

        #expect(snapshot.directPeerSnapshot?.id == peerUserID)
        #expect(snapshot.directPeerSnapshot?.email == "peer@example.com")
        #expect(snapshot.directPeerSnapshot?.avatarPreset == .forest)
        #expect(snapshot.isDirectPeerBlocked)
        #expect(!snapshot.canSendMessages)
        #expect(snapshot.composerDisabledReason == "已屏蔽对方")
    }

    @Test func groupMuteAllProjectsMemberComposerRestriction() {
        let conversationID = "ffffffff-ffff-ffff-ffff-ffffffffffff"
        let conversation = makeConversation(
            id: conversationID,
            kind: .group,
            muteAll: true,
            members: [makeMember(id: currentUserID, role: .member, memberNickname: "我")],
            messages: [],
            pendingMessages: []
        )

        let snapshot = IMChatPageSnapshotBuilder().build(
            conversationID: conversationID,
            generation: 1,
            conversations: [conversation],
            queueSummary: IMConversationQueueSummary(queuedCount: 0, sendingCount: 0, retryableIssueCount: 0),
            receiptSummary: nil,
            isLoadingMessages: false,
            isLoadingMembers: false,
            currentUserID: currentUserID,
            blockedUserIDs: []
        )

        #expect(snapshot.currentGroupRole == .member)
        #expect(snapshot.currentMemberNickname == "我")
        #expect(!snapshot.canSendMessages)
        #expect(snapshot.composerDisabledReason == "全员禁言中")
    }

    @Test func contextSnapshotProjectsConversationStripFields() {
        let conversationID = "99999999-9999-9999-9999-999999999999"
        let conversation = makeConversation(
            id: conversationID,
            kind: .group,
            notice: "今晚 8 点同步",
            avatarPreset: .forest,
            muteAll: true,
            members: [makeMember(id: currentUserID, role: .admin)],
            messages: [],
            pendingMessages: [],
            isPinned: true,
            isMuted: true
        )

        let snapshot = IMChatPageSnapshotBuilder().build(
            conversationID: conversationID,
            generation: 1,
            conversations: [conversation],
            queueSummary: IMConversationQueueSummary(queuedCount: 0, sendingCount: 0, retryableIssueCount: 0),
            receiptSummary: nil,
            isLoadingMessages: false,
            isLoadingMembers: true,
            currentUserID: currentUserID,
            blockedUserIDs: []
        )

        let context = snapshot.contextSnapshot

        #expect(context.kind == .group)
        #expect(context.kindText == "群聊")
        #expect(context.kindIcon == "person.3")
        #expect(context.memberCount == 2)
        #expect(context.currentGroupRole == .admin)
        #expect(context.isPinned)
        #expect(context.isMuted)
        #expect(context.isMuteAll)
        #expect(context.notice == "今晚 8 点同步")
        #expect(context.showsLoadingIndicator)
        #expect(context.shouldShow)
        #expect(snapshot.metadata.title == "Conversation")
        #expect(snapshot.metadata.notice == "今晚 8 点同步")
        #expect(snapshot.metadata.avatarPreset == .forest)
        #expect(snapshot.metadata.muteAll)
    }

    @Test func pendingMessageRowSnapshotProjectsActionCapabilities() throws {
        let conversationID = "88888888-8888-8888-8888-888888888888"
        let queued = makePendingMessage(
            id: "queued",
            conversationID: conversationID,
            deliveryState: .queued(message: "等待发送")
        )
        let failed = makePendingMessage(
            id: "failed",
            conversationID: conversationID,
            deliveryState: .failed(message: "网络错误")
        )
        let conversation = makeConversation(
            id: conversationID,
            kind: .direct,
            messages: [],
            pendingMessages: [queued, failed]
        )
        let snapshot = IMChatPageSnapshotBuilder().build(
            conversationID: conversationID,
            generation: 1,
            conversations: [conversation],
            queueSummary: IMConversationQueueSummary(queuedCount: 0, sendingCount: 0, retryableIssueCount: 0),
            receiptSummary: nil,
            isLoadingMessages: false,
            isLoadingMembers: false,
            currentUserID: currentUserID,
            blockedUserIDs: [],
            isRetryablePendingMessageFailure: { message in
                message.id == "failed"
            }
        )

        let pendingRows = Dictionary(
            uniqueKeysWithValues: snapshot.timelineRows.compactMap { row -> (String, IMChatPendingMessageRowSnapshot)? in
                guard case .pendingMessage(let rowSnapshot) = row else {
                    return nil
                }
                return (rowSnapshot.localMessageID, rowSnapshot)
            }
        )
        let queuedRow = try #require(pendingRows["queued"])
        let failedRow = try #require(pendingRows["failed"])

        #expect(queuedRow.localMessageID == "queued")
        #expect(queuedRow.text == "queued")
        #expect(queuedRow.senderUserID == currentUserID)
        #expect(!queuedRow.createdAtText.isEmpty)
        #expect(queuedRow.deliveryDisplay.text == "待发送: 等待发送")
        #expect(queuedRow.deliveryDisplay.icon == "clock.badge.exclamationmark")
        #expect(queuedRow.deliveryDisplay.tone == .orange)
        #expect(queuedRow.canCancel)
        #expect(!queuedRow.canRetry)
        #expect(failedRow.localMessageID == "failed")
        #expect(failedRow.text == "failed")
        #expect(failedRow.deliveryDisplay.text == "失败: 网络错误")
        #expect(failedRow.deliveryDisplay.icon == "exclamationmark.circle.fill")
        #expect(failedRow.deliveryDisplay.tone == .red)
        #expect(!failedRow.canCancel)
        #expect(failedRow.canRetry)
    }

    @Test func messageRowSnapshotProjectsMediaDownloadState() throws {
        let conversationID = "99999999-9999-9999-9999-999999999999"
        let localDownloadState = IMMessageLocalDownloadState(
            destinationFilePath: "/tmp/photo.jpg",
            status: .paused(
                progress: IMMessageLocalDownloadProgressSnapshot(
                    transferredBytes: 400,
                    totalBytes: 1_000
                )
            )
        )
        let message = try makeMessage(
            id: "media-message",
            conversationID: conversationID,
            senderUserID: peerUserID,
            serverSequence: 1,
            timelineSequence: 1,
            direction: .incoming,
            deliveryState: .received,
            content: testMessageContent(
                kind: IMMessageContentType.image.rawValue,
                body: [
                    "assetID": "asset-1",
                    "mimeType": "image/jpeg",
                    "byteSize": "1024",
                    "filename": "photo.jpg",
                    "width": "320",
                    "height": "240"
                ]
            ),
            localDownloadState: localDownloadState
        )
        let conversation = makeConversation(
            id: conversationID,
            kind: .direct,
            messages: [message],
            pendingMessages: []
        )
        let snapshot = IMChatPageSnapshotBuilder().build(
            conversationID: conversationID,
            generation: 1,
            conversations: [conversation],
            queueSummary: IMConversationQueueSummary(queuedCount: 0, sendingCount: 0, retryableIssueCount: 0),
            receiptSummary: nil,
            isLoadingMessages: false,
            isLoadingMembers: false,
            currentUserID: currentUserID,
            blockedUserIDs: []
        )

        let row = try #require(snapshot.timelineRows.first)
        guard case .message(let messageRow) = row else {
            Issue.record("Expected message row")
            return
        }

        #expect(messageRow.mediaDownload?.asset.assetID == "asset-1")
        #expect(messageRow.mediaDownload?.localMessageID == "media-message")
        #expect(messageRow.mediaDownload?.asset.filename == "photo.jpg")
        #expect(messageRow.mediaDownload?.localDownloadState == localDownloadState)
        #expect(snapshot.mediaDownloadSnapshots.map(\.localMessageID) == ["media-message"])
    }

    @MainActor
    @Test func storeProjectsChatPageSnapshotFromCurrentState() {
        let conversationID = "77777777-7777-7777-7777-777777777777"
        let receipt = IMConversationReceiptSummaryResponseBody(
            conversationID: UUID(uuidString: conversationID)!,
            deliveredThroughSequence: 8,
            readThroughSequence: 8,
            readableMemberCount: 2
        )
        let store = IMConversationStore()
        store.replaceConversationSummaries([
            IMConversationSummaryResponseBody(
                id: UUID(uuidString: conversationID)!,
                title: "Conversation",
                kind: IMConversationKind.group.rawValue,
                memberCount: 2,
                memberUserIDs: [currentUserID, peerUserID],
                lastMessage: nil,
                createdAt: Date(timeIntervalSince1970: 1),
                updatedAt: Date(timeIntervalSince1970: 10)
            )
        ])
        store.setReceiptSummary(receipt, for: conversationID)
        store.setLoadingMembers(true)
        store.queueOutgoingText(
            "pending",
            conversationID: conversationID,
            senderUserID: currentUserID
        )

        let snapshot = store.chatPageSnapshot(
            for: conversationID,
            currentUserID: currentUserID,
            blockedUserIDs: []
        )

        #expect(snapshot.generation > 0)
        #expect(snapshot.conversationID == conversationID)
        #expect(snapshot.timelineRows.count == 1)
        #expect(snapshot.metrics.timelineItemCount == 1)
        #expect(snapshot.latestTimelineItemIsCurrentUserOutgoing)
        #expect(snapshot.queueSummary.queuedCount == 1)
        #expect(snapshot.receiptSummary == IMChatReceiptSummarySnapshot(
            deliveredThroughSequence: 8,
            readThroughSequence: 8,
            readableMemberCount: 2
        ))
        #expect(snapshot.contextSnapshot.showsLoadingIndicator)
    }


    private func makeConversation(
        id: String,
        kind: IMConversationKind,
        directPeer: IMDirectPeer? = nil,
        notice: String? = nil,
        avatarPreset: IMConversationAvatarPreset? = nil,
        muteAll: Bool = false,
        members: [IMConversationMember] = [],
        messages: [IMConversationMessage],
        pendingMessages: [IMPendingConversationMessage],
        notices: [IMTimelineNotice] = [],
        isPinned: Bool = false,
        isMuted: Bool = false,
        hasMoreHistory: Bool = false
    ) -> IMConversation {
        IMConversation(
            id: id,
            title: "Conversation",
            kind: kind,
            directPeer: directPeer,
            notice: notice,
            avatarPreset: avatarPreset,
            muteAll: muteAll,
            memberCount: 2,
            memberUserIDs: [currentUserID, peerUserID],
            members: members,
            messages: messages,
            pendingMessages: pendingMessages,
            notices: notices,
            lastMessagePreviewText: "",
            hasMoreHistory: hasMoreHistory,
            serverLastReadSequence: 0,
            serverUnreadCount: 0,
            localUnreadDelta: 0,
            isPinned: isPinned,
            isMuted: isMuted,
            updatedAt: Date(timeIntervalSince1970: 10)
        )
    }

    private func makeMember(
        id: UUID,
        role: IMConversationMemberRole,
        memberNickname: String? = nil
    ) -> IMConversationMember {
        IMConversationMember(
            id: id,
            email: "\(id.uuidString.lowercased())@example.com",
            role: role,
            memberNickname: memberNickname
        )
    }

    private func makePendingMessage(
        id: String,
        conversationID: String,
        deliveryState: IMMessageDeliveryState
    ) -> IMPendingConversationMessage {
        IMPendingConversationMessage(
            localMessageID: id,
            clientMessageID: id,
            conversationID: conversationID,
            senderUserID: currentUserID,
            content: testMessageContent(kind: "rich_text", body: ["text": id]),
            createdAt: Date(timeIntervalSince1970: 20),
            deliveryState: deliveryState
        )
    }

    private func makeMessage(
        id: String,
        serverMessageID: String? = nil,
        conversationID: String,
        senderUserID: UUID,
        serverSequence: UInt64,
        timelineSequence: UInt64,
        direction: IMMessageDirection,
        deliveryState: IMMessageDeliveryState,
        content: IMMessageContent? = nil,
        localDownloadState: IMMessageLocalDownloadState? = nil
    ) throws -> IMConversationMessage {
        try IMConversationMessage(
            id: id,
            conversationID: conversationID,
            clientMessageID: nil,
            serverMessageID: serverMessageID ?? id,
            senderUserID: senderUserID,
            serverSequence: serverSequence,
            timelineSequence: timelineSequence,
            content: content ?? testMessageContent(kind: "rich_text", body: ["text": id]),
            direction: direction,
            createdAt: Date(timeIntervalSince1970: Double(timelineSequence)),
            deliveryState: deliveryState,
            localDownloadState: localDownloadState
        )
    }
}
