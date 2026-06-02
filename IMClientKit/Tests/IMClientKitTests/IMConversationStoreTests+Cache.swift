import Foundation
import Testing
@testable import IMClientKit

extension IMConversationStoreTests {
    @Test func domainEventBatchStopsBeforeMissingRequiredNoticeAndDoesNotAdvanceCursorPastIt() throws {
        let store = IMConversationStore()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let messageID = UUID(uuidString: "bbbbbbbb-1111-2222-3333-cccccccccccc")!
        let firstEvent = IMTCPChatDomainEventPayload(
            eventID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            eventType: .messageCreated,
            aggregateType: "conversation",
            aggregateID: conversationID,
            aggregateSequence: 1,
            occurredAt: Date(timeIntervalSince1970: 1_700_900_001),
            actorUserID: Self.peerUserID,
            conversation: nil,
            ownerCursor: 1,
            ownerAggregateSequence: 1,
            body: .messageCreated(
                message: IMConversationMessageResponseBody(
                    id: messageID,
                    conversationID: conversationID,
                    senderUserID: Self.peerUserID,
                    serverSequence: 1,
                    timelineSequence: 1,
                    content: .richText(.plain("first")),
                    createdAt: Date(timeIntervalSince1970: 1_700_900_001)
                ),
                clientMessageID: nil
            )
        )
        let missingNoticeEvent = IMTCPChatDomainEventPayload(
            eventID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            eventType: .memberAdded,
            aggregateType: "conversation",
            aggregateID: conversationID,
            aggregateSequence: 2,
            occurredAt: Date(timeIntervalSince1970: 1_700_900_002),
            actorUserID: Self.peerUserID,
            conversation: nil,
            requiresTimelineNotice: true,
            ownerCursor: 2,
            ownerAggregateSequence: 2,
            body: .memberChanged(memberUserIDs: [Self.peerUserID])
        )
        let thirdEvent = IMTCPChatDomainEventPayload(
            eventID: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            eventType: .messageCreated,
            aggregateType: "conversation",
            aggregateID: conversationID,
            aggregateSequence: 3,
            occurredAt: Date(timeIntervalSince1970: 1_700_900_003),
            actorUserID: Self.peerUserID,
            conversation: nil,
            ownerCursor: 3,
            ownerAggregateSequence: 3,
            body: .messageCreated(
                message: IMConversationMessageResponseBody(
                    id: UUID(uuidString: "cccccccc-1111-2222-3333-dddddddddddd")!,
                    conversationID: conversationID,
                    senderUserID: Self.peerUserID,
                    serverSequence: 2,
                    timelineSequence: 3,
                    content: .richText(.plain("third")),
                    createdAt: Date(timeIntervalSince1970: 1_700_900_003)
                ),
                clientMessageID: nil
            )
        )

        let outcome = store.applyDomainEvents(
            [
                Self.envelope(cursor: 1, payload: firstEvent),
                Self.envelope(cursor: 2, payload: missingNoticeEvent),
                Self.envelope(cursor: 3, payload: thirdEvent)
            ],
            nextCursor: 3,
            currentUserID: Self.currentUserID
        )

        #expect(outcome.shouldFetchDomainEvents == true)
        #expect(store.domainEventSyncCursor == 1)
        #expect(store.domainEventDebugMetrics.missingRequiredNotice == 1)
        #expect(store.conversations.first?.messages.map(\.text) == ["first"])
    }

    @Test func deferredOutOfOrderEventAllowsCursorAdvanceAndPersistsDeferredEnvelope() {
        let store = IMConversationStore()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let missingMessageID = UUID(uuidString: "bbbbbbbb-1111-2222-3333-cccccccccccc")!
        let editEvent = IMTCPChatDomainEventPayload(
            eventID: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
            eventType: .messageEdited,
            aggregateType: "conversation",
            aggregateID: conversationID,
            aggregateSequence: 2,
            occurredAt: Date(timeIntervalSince1970: 1_700_900_010),
            actorUserID: Self.peerUserID,
            conversation: nil,
            ownerCursor: 1,
            ownerAggregateSequence: 1,
            body: .messageEdited(
                messageID: missingMessageID,
                body: .plain("edited"),
                editedAt: Date(timeIntervalSince1970: 1_700_900_011),
                message: nil
            )
        )

        let outcome = store.applyDomainEvents(
            [Self.envelope(cursor: 1, payload: editEvent)],
            nextCursor: 1,
            currentUserID: Self.currentUserID
        )
        let snapshot = store.makeCacheSnapshot(lastSummaryRefreshAt: nil)

        #expect(outcome.shouldFetchDomainEvents == true)
        #expect(store.domainEventSyncCursor == 1)
        #expect(snapshot.domainEventState.deferredEvents.map(\.eventID) == [editEvent.eventID])
    }

    @Test func domainEventBatchStopsAtOwnerCursorGap() {
        let store = IMConversationStore()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let firstEvent = IMTCPChatDomainEventPayload(
            eventID: UUID(uuidString: "77777777-7777-7777-7777-777777777777")!,
            eventType: .messageCreated,
            aggregateType: "conversation",
            aggregateID: conversationID,
            aggregateSequence: 1,
            occurredAt: Date(timeIntervalSince1970: 1_700_900_030),
            actorUserID: Self.peerUserID,
            conversation: nil,
            ownerCursor: 1,
            ownerAggregateSequence: 1,
            body: .messageCreated(
                message: IMConversationMessageResponseBody(
                    id: UUID(uuidString: "dddddddd-1111-2222-3333-eeeeeeeeeeee")!,
                    conversationID: conversationID,
                    senderUserID: Self.peerUserID,
                    serverSequence: 1,
                    timelineSequence: 1,
                    content: .richText(.plain("first")),
                    createdAt: Date(timeIntervalSince1970: 1_700_900_030)
                ),
                clientMessageID: nil
            )
        )
        let skippedCursorEvent = IMTCPChatDomainEventPayload(
            eventID: UUID(uuidString: "88888888-8888-8888-8888-888888888888")!,
            eventType: .messageCreated,
            aggregateType: "conversation",
            aggregateID: conversationID,
            aggregateSequence: 3,
            occurredAt: Date(timeIntervalSince1970: 1_700_900_032),
            actorUserID: Self.peerUserID,
            conversation: nil,
            ownerCursor: 3,
            ownerAggregateSequence: 3,
            body: .messageCreated(
                message: IMConversationMessageResponseBody(
                    id: UUID(uuidString: "eeeeeeee-1111-2222-3333-ffffffffffff")!,
                    conversationID: conversationID,
                    senderUserID: Self.peerUserID,
                    serverSequence: 2,
                    timelineSequence: 3,
                    content: .richText(.plain("third")),
                    createdAt: Date(timeIntervalSince1970: 1_700_900_032)
                ),
                clientMessageID: nil
            )
        )

        let outcome = store.applyDomainEvents(
            [
                Self.envelope(cursor: 1, payload: firstEvent),
                Self.envelope(cursor: 3, payload: skippedCursorEvent)
            ],
            nextCursor: 3,
            currentUserID: Self.currentUserID
        )

        #expect(outcome.shouldFetchDomainEvents == true)
        #expect(store.domainEventSyncCursor == 1)
        #expect(store.domainEventDebugMetrics.catchUpCursorGap == 1)
        #expect(store.conversations.first?.messages.map(\.text) == ["first"])
    }

    @Test func domainEventProjectionReducerClassifiesRequiredNoticeAndMissingMessage() {
        let reducer = DomainEventProjectionReducer()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let messageID = UUID(uuidString: "bbbbbbbb-1111-2222-3333-cccccccccccc")!
        let snapshot = DomainEventProjectionReducer.DependencySnapshot(
            processedEventIDs: [],
            ownerAggregateHighWatermarks: [:],
            existingMessageKeys: []
        )

        let missingNotice = IMTCPChatDomainEventPayload(
            eventID: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
            eventType: .memberAdded,
            aggregateType: "conversation",
            aggregateID: conversationID,
            aggregateSequence: 1,
            occurredAt: Date(timeIntervalSince1970: 1_700_900_020),
            actorUserID: Self.peerUserID,
            conversation: nil,
            requiresTimelineNotice: true,
            ownerCursor: 1,
            ownerAggregateSequence: 1,
            body: .memberChanged(memberUserIDs: [Self.peerUserID])
        )
        let outOfOrderEdit = IMTCPChatDomainEventPayload(
            eventID: UUID(uuidString: "66666666-6666-6666-6666-666666666666")!,
            eventType: .messageEdited,
            aggregateType: "conversation",
            aggregateID: conversationID,
            aggregateSequence: 2,
            occurredAt: Date(timeIntervalSince1970: 1_700_900_021),
            actorUserID: Self.peerUserID,
            conversation: nil,
            ownerCursor: 2,
            ownerAggregateSequence: 1,
            body: .messageEdited(
                messageID: messageID,
                body: .plain("edited"),
                editedAt: Date(timeIntervalSince1970: 1_700_900_022),
                message: nil
            )
        )

        if case .requestCatchUp = reducer.reduce(
            event: missingNotice,
            currentUserID: Self.currentUserID,
            dependencies: snapshot
        ) {
            // Expected path.
        } else {
            Issue.record("Missing required notice should request catch-up.")
        }

        if case .deferEvent(let reason, let missingKey, let deferredConversationID) = reducer.reduce(
            event: outOfOrderEdit,
            currentUserID: Self.currentUserID,
            dependencies: snapshot
        ) {
            #expect(reason == .missingMessage)
            #expect(missingKey == .message(messageID.uuidString))
            #expect(deferredConversationID == conversationID.uuidString)
        } else {
            Issue.record("Out-of-order edit should be deferred.")
        }
    }

    private static func envelope(
        cursor: UInt64,
        payload: IMTCPChatDomainEventPayload
    ) -> SessionClient.IMDomainEventDeliveryEnvelope {
        SessionClient.IMDomainEventDeliveryEnvelope(
            cursor: cursor,
            eventID: payload.eventID,
            ownerAggregateSequence: payload.ownerAggregateSequence ?? 0,
            eventPBBase64: "",
            payload: payload
        )
    }

    @Test func replaceMembersStoresConversationParticipants() {
        let store = IMConversationStore()
        let conversationID = "AAAAAAAA-1111-2222-3333-BBBBBBBBBBBB"

        store.openConversation(id: conversationID)
        store.replaceMembers(
            in: conversationID,
            members: [
                IMConversationMemberResponseBody(id: Self.peerUserID, email: "peer@example.com"),
                IMConversationMemberResponseBody(id: Self.currentUserID, email: "self@example.com")
            ]
        )

        #expect(store.selectedConversation?.members.map(\.email) == ["peer@example.com", "self@example.com"])
        #expect(store.selectedConversation?.memberUserIDs.count == 2)
        #expect(store.selectedConversation?.memberCount == 2)
    }


    @Test func removeConversationRemovesSelectionAndFallsBackToRemainingConversation() {
        let store = IMConversationStore()
        let currentConversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let restoredConversationID = UUID(uuidString: "bbbbbbbb-1111-2222-3333-cccccccccccc")!

        store.replaceConversationSummaries(
            [
                IMConversationSummaryResponseBody(
                    id: currentConversationID,
                    title: "Current",
                    kind: IMConversationKind.group.rawValue,
                    memberCount: 3,
                    memberUserIDs: [Self.currentUserID, Self.peerUserID],
                    lastMessage: nil,
                    createdAt: Date(timeIntervalSince1970: 1_700_200_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_300_000)
                ),
                IMConversationSummaryResponseBody(
                    id: restoredConversationID,
                    title: "Fallback",
                    kind: IMConversationKind.direct.rawValue,
                    memberCount: 2,
                    memberUserIDs: [Self.currentUserID, Self.peerUserID],
                    lastMessage: nil,
                    createdAt: Date(timeIntervalSince1970: 1_700_100_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_100_000)
                )
            ]
        )

        store.openConversation(id: currentConversationID.uuidString)
        store.removeConversation(id: currentConversationID.uuidString)

        #expect(store.conversations.count == 1)
        #expect(store.conversations.first?.id == restoredConversationID.uuidString)
        #expect(store.selectedConversationID == restoredConversationID.uuidString)
    }


    @Test func cacheSnapshotRoundTripsConversationMessagesAndSelection() {
        let store = IMConversationStore()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let conversationIDString = conversationID.uuidString
        let updatedAt = Date(timeIntervalSince1970: 1_700_500_000)
        let lastSummaryRefreshAt = Date(timeIntervalSince1970: 1_700_500_100)

        store.replaceConversationSummaries(
            [
                IMConversationSummaryResponseBody(
                    id: conversationID,
                    title: "Cache Target",
                    kind: IMConversationKind.direct.rawValue,
                    directMessagingState: IMDirectMessagingState.frozenAfterUnfriend.rawValue,
                    directPeer: IMDirectPeerResponseBody(id: Self.peerUserID, email: "cache-peer@example.com"),
                    memberCount: 2,
                    memberUserIDs: [Self.currentUserID, Self.peerUserID],
                    lastMessage: nil,
                    createdAt: Date(timeIntervalSince1970: 1_700_400_000),
                    updatedAt: updatedAt
                )
            ]
        )
        store.applyServerSummaryReadState(
            lastReadSequence: 3,
            unreadCount: 2,
            for: conversationIDString
        )
        store.openConversation(id: conversationIDString)
        store.replaceTimelineItems(
            in: conversationIDString,
            messages: [
                IMConversationMessageResponseBody(
                    id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                    conversationID: conversationID,
                    senderUserID: Self.peerUserID,
                    clientMessageID: nil,
                    serverSequence: 3,
                    kind: "rich_text",
                    body: ["text": "cached message"],
                    createdAt: updatedAt
                )
            ],
            currentUserID: Self.currentUserID
        )

        let snapshot = store.makeCacheSnapshot(lastSummaryRefreshAt: lastSummaryRefreshAt)
        let restoredStore = IMConversationStore()
        restoredStore.restoreCacheSnapshot(snapshot)

        #expect(snapshot.lastSummaryRefreshAt == lastSummaryRefreshAt)
        #expect(restoredStore.selectedConversationID == conversationIDString)
        #expect(restoredStore.hasLoadedMessages(for: conversationIDString))
        #expect(restoredStore.selectedConversation?.title == "Cache Target")
        #expect(restoredStore.selectedConversation?.kind == .direct)
        #expect(restoredStore.selectedConversation?.directMessagingState == .frozenAfterUnfriend)
        #expect(restoredStore.selectedConversation?.directPeer == IMDirectPeer(id: Self.peerUserID, email: "cache-peer@example.com"))
        #expect(restoredStore.selectedConversation?.isDirectMessagingFrozen == true)
        #expect(restoredStore.selectedConversation?.canSendMessages == false)
        #expect(restoredStore.selectedConversation?.serverLastReadSequence == 3)
        #expect(restoredStore.selectedConversation?.serverUnreadCount == 2)
        #expect(restoredStore.selectedConversation?.messages.map(\.text) == ["cached message"])
        #expect(restoredStore.selectedConversation?.hasMoreHistory == true)
        #expect(restoredStore.latestLoadedMessageSequence(for: conversationIDString) == 3)
        #expect(restoredStore.oldestLoadedTimelineSequence(for: conversationIDString) == 3)
        #expect(snapshot.metadata.selectedConversationID == conversationIDString)
        #expect(snapshot.cursors == [
            IMSyncCursorState(
                conversationID: conversationIDString,
                hasLoadedMessages: true,
                latestLoadedTimelineSequence: 3,
                oldestLoadedTimelineSequence: 3
            )
        ])
    }


    @Test func cacheSnapshotDoesNotMarkSummaryOnlyConversationAsLoadedForGapSync() {
        let store = IMConversationStore()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!

        let summaries = [
            Self.gapSummary(conversationID: conversationID, latestServerSequence: 20)
        ]
        store.replaceConversationSummaries(summaries)

        let snapshot = store.makeCacheSnapshot(lastSummaryRefreshAt: nil)
        let restoredStore = IMConversationStore()
        restoredStore.restoreCacheSnapshot(snapshot)

        #expect(restoredStore.hasLoadedMessages(for: conversationID.uuidString) == false)
        #expect(restoredStore.latestLoadedMessageSequence(for: conversationID.uuidString) == nil)
        #expect(restoredStore.gapSyncTargets(from: summaries).isEmpty)
    }


    @Test func cacheRestoreTreatsEmptyLoadedConversationWithSummaryMessageAsUnloaded() {
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let conversationIDString = conversationID.uuidString
        let snapshot = IMConversationCacheSnapshot(
            conversations: [
                IMCachedConversationState(
                    id: conversationIDString,
                    title: "Summary Only",
                    kind: .direct,
                    memberCount: 2,
                    memberUserIDs: [Self.currentUserID, Self.peerUserID],
                    messages: [],
                    hasLoadedMessages: true,
                    lastMessagePreviewText: "summary 20",
                    hasMoreHistory: false,
                    latestLoadedTimelineSequence: nil,
                    oldestLoadedTimelineSequence: nil,
                    serverLastReadSequence: 0,
                    serverUnreadCount: 1,
                    updatedAt: Date(timeIntervalSince1970: 1_700_400_020)
                )
            ],
            selectedConversationID: conversationIDString,
            lastSummaryRefreshAt: nil,
            summarySyncToken: nil,
            summaryNextCursor: nil,
            hasMoreConversationSummaries: false
        )

        let restoredStore = IMConversationStore()
        restoredStore.restoreCacheSnapshot(snapshot)

        #expect(restoredStore.hasLoadedMessages(for: conversationIDString) == false)
        #expect(restoredStore.selectedConversation?.messages.isEmpty == true)
        #expect(restoredStore.selectedConversation?.lastMessagePreview == "summary 20")
        #expect(restoredStore.selectedConversation?.unreadCount == 1)
    }


    @Test func cacheRestoreKeepsLoadedEmptyConversationWithoutSummaryMessageLoaded() {
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let conversationIDString = conversationID.uuidString
        let snapshot = IMConversationCacheSnapshot(
            conversations: [
                IMCachedConversationState(
                    id: conversationIDString,
                    title: "Empty",
                    kind: .direct,
                    memberCount: 2,
                    memberUserIDs: [Self.currentUserID, Self.peerUserID],
                    messages: [],
                    hasLoadedMessages: true,
                    lastMessagePreviewText: "暂无消息",
                    hasMoreHistory: false,
                    latestLoadedTimelineSequence: nil,
                    oldestLoadedTimelineSequence: nil,
                    serverLastReadSequence: 0,
                    serverUnreadCount: 0,
                    updatedAt: Date(timeIntervalSince1970: 1_700_400_020)
                )
            ],
            selectedConversationID: conversationIDString,
            lastSummaryRefreshAt: nil,
            summarySyncToken: nil,
            summaryNextCursor: nil,
            hasMoreConversationSummaries: false
        )

        let restoredStore = IMConversationStore()
        restoredStore.restoreCacheSnapshot(snapshot)

        #expect(restoredStore.hasLoadedMessages(for: conversationIDString))
    }


    @Test func cacheSnapshotTrimsMessagesToRecentWindowAndPreservesWindowCursor() throws {
        let store = IMConversationStore()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let conversationIDString = conversationID.uuidString

        store.replaceConversationSummaries([Self.gapSummary(conversationID: conversationID, latestServerSequence: 205)])
        store.replaceTimelineItems(
            in: conversationIDString,
            messages: (1...205).map { sequence in
                Self.messageResponse(conversationID: conversationID, serverSequence: sequence)
            },
            currentUserID: Self.currentUserID
        )

        let snapshot = store.makeCacheSnapshot(lastSummaryRefreshAt: nil)
        let cachedConversation = try #require(snapshot.conversations.first)
        let cursor = try #require(snapshot.cursors.first)

        #expect(cachedConversation.messages.count == IMConversationCacheSnapshot.cachedMessageLimit)
        #expect(cachedConversation.messages.first?.serverSequence == 6)
        #expect(cachedConversation.messages.last?.serverSequence == 205)
        #expect(cursor.latestLoadedTimelineSequence == 205)
        #expect(cursor.oldestLoadedTimelineSequence == 6)
    }


    @Test func cacheSnapshotRoundTripsConversationSummaryPaginationMetadata() {
        let store = IMConversationStore()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!

        store.replaceConversationSummaryWindow(
            [Self.gapSummary(conversationID: conversationID, latestServerSequence: 20)],
            nextCursor: "cursor-page-2",
            hasMore: true
        )

        let snapshot = store.makeCacheSnapshot(lastSummaryRefreshAt: Date(timeIntervalSince1970: 1_700_800_000))
        let restoredStore = IMConversationStore()
        restoredStore.restoreCacheSnapshot(snapshot)

        #expect(snapshot.metadata.summaryNextCursor == "cursor-page-2")
        #expect(snapshot.metadata.hasMoreConversationSummaries == true)
        #expect(restoredStore.conversationSummaryNextCursor == "cursor-page-2")
        #expect(restoredStore.hasMoreConversationSummaries == true)
        #expect(restoredStore.isLoadingMoreConversationSummaries == false)
    }


    @Test func cacheRestoreKeepsPendingAndFailedMessagesWithoutRestoringPendingQueue() {
        let store = IMConversationStore()
        let conversationID = "AAAAAAAA-1111-2222-3333-BBBBBBBBBBBB"
        let failedRequest = store.prepareOutgoingText(
            "failed draft",
            conversationID: conversationID,
            senderUserID: Self.currentUserID
        )
        if let failedRequest {
            store.markOutgoingFailure(requestID: failedRequest.requestID, message: "send failed")
        }
        _ = store.prepareOutgoingText(
            "pending draft",
            conversationID: conversationID,
            senderUserID: Self.currentUserID
        )
        store.queueOutgoingText(
            "queued draft",
            conversationID: conversationID,
            senderUserID: Self.currentUserID
        )

        let snapshot = store.makeCacheSnapshot(lastSummaryRefreshAt: nil)
        let restoredStore = IMConversationStore()
        restoredStore.restoreCacheSnapshot(snapshot)
        restoredStore.markAllPendingMessagesFailed(message: "should not apply")

        #expect(restoredStore.selectedConversation?.pendingMessages.map(\.text) == ["failed draft", "pending draft", "queued draft"])
        #expect(restoredStore.selectedConversation?.pendingMessages.map(\.deliveryState) == [
            .failed(message: "send failed"),
            .unknown(message: "发送状态未确认，请重试。"),
            .queued(message: "等待 IM 长连接恢复后发送。")
        ])
    }


    @Test func cacheRestorePreservesRecoverableOutgoingMediaUploadState() throws {
        let store = IMConversationStore()
        let conversationID = "AAAAAAAA-1111-2222-3333-BBBBBBBBBBBB"
        let sourceFileURL = FileManager.default.temporaryDirectory.appending(path: "cache-media-\(UUID().uuidString).png")
        let asset = IMMediaAsset(
            assetID: "local-cache-asset",
            kind: .image,
            mimeType: "image/png",
            byteSize: 12,
            filename: "cache.png",
            width: 48,
            height: 48
        )

        _ = store.stageOutgoingMediaUpload(
            asset: asset,
            conversationID: conversationID,
            senderUserID: Self.currentUserID,
            sourceFileURL: sourceFileURL
        )
        let localMessageID = try #require(store.selectedConversation?.pendingMessages.first?.id)
        store.markOutgoingUploading(
            localMessageID: localMessageID,
            message: "正在上传附件。",
            uploadID: "upload-cache-1"
        )

        let snapshot = store.makeCacheSnapshot(lastSummaryRefreshAt: nil)
        let restoredStore = IMConversationStore()
        restoredStore.restoreCacheSnapshot(snapshot)

        let restoredMessage = try #require(restoredStore.selectedConversation?.pendingMessages.first)
        #expect(restoredMessage.deliveryState == .uploading(message: "正在上传附件。"))
        #expect(restoredMessage.localTransferState?.sourceFilePath == sourceFileURL.path)
        #expect(restoredMessage.localTransferState?.uploadID == "upload-cache-1")
        #expect(restoredStore.recoverableOutgoingMediaUploads().map(\.localMessageID) == [localMessageID])
    }


    @Test func cacheRestorePreservesLocalMediaDownloadState() throws {
        let store = IMConversationStore()
        let conversationID = "AAAAAAAA-1111-2222-3333-BBBBBBBBBBBB"
        let asset = IMMediaAsset(
            assetID: "download-cache-asset",
            kind: .file,
            mimeType: "application/pdf",
            byteSize: 128,
            filename: "cached.pdf"
        )

        store.replaceConversationSummaries(
            [
                IMConversationSummaryResponseBody(
                    id: UUID(uuidString: conversationID)!,
                    title: "cached media",
                    memberUserIDs: [Self.currentUserID, Self.peerUserID],
                    lastMessage: nil,
                    createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
                )
            ]
        )
        store.replaceTimelineItems(
            in: conversationID,
            messages: [
                IMConversationMessageResponseBody(
                    id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
                    conversationID: UUID(uuidString: conversationID)!,
                    senderUserID: Self.peerUserID,
                    clientMessageID: nil,
                    serverSequence: 1,
                    timelineSequence: 1,
                    content: .file(asset),
                    createdAt: Date(timeIntervalSince1970: 1_700_000_001)
                )
            ],
            currentUserID: Self.currentUserID
        )

        let messageID = try #require(store.selectedConversation?.messages.first?.id)
        let destinationURL = FileManager.default.temporaryDirectory.appending(path: "cached-download-\(UUID().uuidString).pdf")
        let transferTaskID = IMTransferTaskID(
            sessionIdentifier: "tests.im.cache.download",
            taskIdentifier: 88
        )
        store.updateLocalDownloadState(
            messageID: messageID,
            state: IMMessageLocalDownloadState(
                destinationFilePath: destinationURL.path,
                status: .paused(
                    progress: IMMessageLocalDownloadProgressSnapshot(
                        transferredBytes: 64,
                        totalBytes: 128,
                        resumedBytes: 32
                    )
                ),
                taskID: transferTaskID
            )
        )

        let snapshot = store.makeCacheSnapshot(lastSummaryRefreshAt: nil)
        let restoredStore = IMConversationStore()
        restoredStore.restoreCacheSnapshot(snapshot)

        let restoredMessage = try #require(restoredStore.selectedConversation?.messages.first)
        #expect(restoredMessage.localDownloadState?.destinationFilePath == destinationURL.path)
        #expect(restoredMessage.localDownloadState?.status == .paused(
            progress: IMMessageLocalDownloadProgressSnapshot(
                transferredBytes: 64,
                totalBytes: 128,
                resumedBytes: 32
            )
        ))
        #expect(restoredMessage.transferTaskID == transferTaskID)
    }


    @Test func cacheSnapshotCarriesTransferSnapshots() throws {
        let store = IMConversationStore()
        let transferSnapshot = IMTransferSnapshot(
            taskID: IMTransferTaskID(
                sessionIdentifier: "tests.im.cache.download",
                taskIdentifier: 77
            ),
            kind: .download,
            intent: .mediaDownload,
            state: .waitingForConnectivity(
                progress: IMMessageLocalDownloadProgressSnapshot(
                    transferredBytes: 12,
                    totalBytes: 48,
                    resumedBytes: 4
                )
            ),
            destinationURL: FileManager.default.temporaryDirectory
                .appending(path: "transfer-cache-\(UUID().uuidString).bin")
        )

        let snapshot = store.makeCacheSnapshot(
            lastSummaryRefreshAt: nil,
            transferSnapshots: [transferSnapshot]
        )

        #expect(snapshot.transferSnapshots == [transferSnapshot])
    }
}
