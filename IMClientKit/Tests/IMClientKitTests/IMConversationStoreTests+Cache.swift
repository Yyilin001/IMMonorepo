import Foundation
import Testing
@testable import IMClientKit

extension IMConversationStoreTests {
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
        store.replaceMessages(
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
        #expect(restoredStore.latestLoadedServerSequence(for: conversationIDString) == 3)
        #expect(restoredStore.oldestLoadedServerSequence(for: conversationIDString) == 3)
        #expect(snapshot.metadata.selectedConversationID == conversationIDString)
        #expect(snapshot.cursors == [
            IMSyncCursorState(
                conversationID: conversationIDString,
                hasLoadedMessages: true,
                latestSyncedServerSequence: 3,
                oldestLoadedServerSequence: 3
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
        #expect(restoredStore.latestLoadedServerSequence(for: conversationID.uuidString) == nil)
        #expect(restoredStore.gapSyncTargets(from: summaries).isEmpty)
    }


    @Test func cacheSnapshotTrimsMessagesToRecentWindowAndPreservesWindowCursor() throws {
        let store = IMConversationStore()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let conversationIDString = conversationID.uuidString

        store.replaceConversationSummaries([Self.gapSummary(conversationID: conversationID, latestServerSequence: 205)])
        store.replaceMessages(
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
        #expect(cursor.latestSyncedServerSequence == 205)
        #expect(cursor.oldestLoadedServerSequence == 6)
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

        #expect(restoredStore.selectedConversation?.messages.map(\.text) == ["failed draft", "pending draft", "queued draft"])
        #expect(restoredStore.selectedConversation?.messages.map(\.deliveryState) == [
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
        let localMessageID = try #require(store.selectedConversation?.messages.first?.id)
        store.markOutgoingUploading(
            localMessageID: localMessageID,
            message: "正在上传附件。",
            uploadID: "upload-cache-1"
        )

        let snapshot = store.makeCacheSnapshot(lastSummaryRefreshAt: nil)
        let restoredStore = IMConversationStore()
        restoredStore.restoreCacheSnapshot(snapshot)

        let restoredMessage = try #require(restoredStore.selectedConversation?.messages.first)
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
        store.replaceMessages(
            in: conversationID,
            messages: [
                IMConversationMessageResponseBody(
                    id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
                    conversationID: UUID(uuidString: conversationID)!,
                    senderUserID: Self.peerUserID,
                    clientMessageID: nil,
                    serverSequence: 1,
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
