import Foundation
import Testing
@testable import IMClientKit

@MainActor
extension IMConversationStoreTests {
    @Test func replaceConversationSummariesImportsServerPreview() {
        let store = IMConversationStore()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!

        store.replaceConversationSummaries(
            [
                IMConversationSummaryResponseBody(
                    id: conversationID,
                    title: nil,
                    memberUserIDs: [Self.currentUserID, Self.peerUserID],
                    lastMessage: IMMessagePreviewResponseBody(
                        id: UUID(uuidString: "cccccccc-1111-2222-3333-dddddddddddd")!,
                        senderUserID: Self.peerUserID,
                        serverSequence: 10,
                        kind: "rich_text",
                        body: ["text": "preview text"],
                        createdAt: Date(timeIntervalSince1970: 1_700_300_000)
                    ),
                    createdAt: Date(timeIntervalSince1970: 1_700_200_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_300_000)
                )
            ]
        )

        #expect(store.conversations.count == 1)
        #expect(store.selectedConversation?.lastMessagePreview == "preview text")
        #expect(store.selectedConversation?.title == "会话 aaaaaaaa")
        #expect(store.selectedConversation?.kind == .group)
        #expect(store.selectedConversation?.memberCount == 2)
        #expect(store.selectedConversation?.memberUserIDs.count == 2)
    }

    @Test func replaceConversationSummariesRefreshesKindAndMemberCount() {
        let store = IMConversationStore()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!

        store.replaceConversationSummaries(
            [
                IMConversationSummaryResponseBody(
                    id: conversationID,
                    title: nil,
                    kind: IMConversationKind.direct.rawValue,
                    memberCount: 2,
                    memberUserIDs: [Self.currentUserID, Self.peerUserID],
                    lastMessage: nil,
                    createdAt: Date(timeIntervalSince1970: 1_700_200_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_200_000)
                )
            ]
        )

        store.replaceConversationSummaries(
            [
                IMConversationSummaryResponseBody(
                    id: conversationID,
                    title: "Study Group",
                    kind: IMConversationKind.group.rawValue,
                    memberCount: 3,
                    memberUserIDs: [Self.currentUserID, Self.peerUserID],
                    lastMessage: nil,
                    createdAt: Date(timeIntervalSince1970: 1_700_200_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_300_000)
                )
            ]
        )

        #expect(store.selectedConversation?.kind == .group)
        #expect(store.selectedConversation?.memberCount == 3)
        #expect(store.selectedConversation?.title == "Study Group")
    }

    @Test func replaceConversationSummaryWindowTracksPaginationState() {
        let store = IMConversationStore()
        let firstConversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let secondConversationID = UUID(uuidString: "bbbbbbbb-1111-2222-3333-cccccccccccc")!

        store.replaceConversationSummaryWindow(
            [
                Self.gapSummary(conversationID: firstConversationID, latestServerSequence: 20),
                Self.gapSummary(conversationID: secondConversationID, latestServerSequence: 10)
            ],
            nextCursor: "cursor-page-2",
            hasMore: true
        )

        #expect(store.conversations.map(\.id) == [
            firstConversationID.uuidString,
            secondConversationID.uuidString
        ])
        #expect(store.selectedConversationID == firstConversationID.uuidString)
        #expect(store.conversationSummaryNextCursor == "cursor-page-2")
        #expect(store.hasMoreConversationSummaries == true)
        #expect(store.conversationSummaryPaginationAnchorID == secondConversationID.uuidString)
        #expect(store.isLoadingMoreConversationSummaries == false)
    }

    @Test func asyncSummaryWindowUsesClientStateEngineAndProjectsMainActorState() async {
        let store = IMConversationStore()
        let firstConversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let secondConversationID = UUID(uuidString: "bbbbbbbb-1111-2222-3333-cccccccccccc")!
        let thirdConversationID = UUID(uuidString: "cccccccc-1111-2222-3333-dddddddddddd")!

        await store.replaceConversationSummaryWindowAsync(
            [
                Self.gapSummary(conversationID: firstConversationID, latestServerSequence: 30),
                Self.gapSummary(conversationID: secondConversationID, latestServerSequence: 20)
            ],
            nextCursor: "cursor-page-2",
            hasMore: true
        )
        store.setLoadingMoreConversationSummaries(true)
        await store.appendConversationSummaryWindowAsync(
            [Self.gapSummary(conversationID: thirdConversationID, latestServerSequence: 10)],
            nextCursor: nil,
            hasMore: false
        )

        #expect(store.conversations.map(\.id) == [
            firstConversationID.uuidString,
            secondConversationID.uuidString,
            thirdConversationID.uuidString
        ])
        #expect(store.selectedConversationID == firstConversationID.uuidString)
        #expect(store.conversationSummaryNextCursor == nil)
        #expect(store.hasMoreConversationSummaries == false)
        #expect(store.conversationSummaryPaginationAnchorID == thirdConversationID.uuidString)
        #expect(store.isLoadingMoreConversationSummaries == false)
    }

    @Test func asyncMessageRemovalUsesClientStateEngineAndProjectsMainActorState() async throws {
        let store = IMConversationStore()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let firstMessage = Self.messageResponse(conversationID: conversationID, serverSequence: 1)
        let secondMessage = Self.messageResponse(conversationID: conversationID, serverSequence: 2)

        await store.replaceConversationSummaryWindowAsync(
            [Self.gapSummary(conversationID: conversationID, latestServerSequence: 2)],
            nextCursor: nil,
            hasMore: false
        )
        store.replaceTimelineItems(
            in: conversationID.uuidString,
            messages: [firstMessage, secondMessage],
            currentUserID: Self.currentUserID
        )

        await store.removeMessagesAsync(
            ids: [secondMessage.id.uuidString],
            from: conversationID.uuidString
        )

        let conversationAfterRemove = try #require(store.conversations.first)
        #expect(conversationAfterRemove.messages.map(\.serverMessageID) == [firstMessage.id.uuidString])
        #expect(conversationAfterRemove.lastMessagePreviewText == "local 1")

        await store.clearMessagesAsync(in: conversationID.uuidString)

        let conversationAfterClear = try #require(store.conversations.first)
        #expect(conversationAfterClear.messages.isEmpty)
        #expect(conversationAfterClear.lastMessagePreviewText == "")
        #expect(conversationAfterClear.unreadCount == 0)
    }

    @Test func appendConversationSummaryWindowAppendsOlderPageAndUpdatesCursor() {
        let store = IMConversationStore()
        let newestConversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let middleConversationID = UUID(uuidString: "bbbbbbbb-1111-2222-3333-cccccccccccc")!
        let oldestConversationID = UUID(uuidString: "cccccccc-1111-2222-3333-dddddddddddd")!

        store.replaceConversationSummaryWindow(
            [
                Self.gapSummary(conversationID: newestConversationID, latestServerSequence: 30),
                Self.gapSummary(conversationID: middleConversationID, latestServerSequence: 20)
            ],
            nextCursor: "cursor-page-2",
            hasMore: true
        )
        store.setLoadingMoreConversationSummaries(true)

        store.appendConversationSummaryWindow(
            [Self.gapSummary(conversationID: oldestConversationID, latestServerSequence: 10)],
            nextCursor: nil,
            hasMore: false
        )

        #expect(store.conversations.map(\.id) == [
            newestConversationID.uuidString,
            middleConversationID.uuidString,
            oldestConversationID.uuidString
        ])
        #expect(store.conversationSummaryNextCursor == nil)
        #expect(store.hasMoreConversationSummaries == false)
        #expect(store.conversationSummaryPaginationAnchorID == oldestConversationID.uuidString)
        #expect(store.isLoadingMoreConversationSummaries == false)
    }

    @Test func pinnedMutedSummaryStateAffectsOrderingAndAggregateUnread() {
        let store = IMConversationStore()
        let mutedPinnedConversationID = UUID(uuidString: "dddddddd-1111-2222-3333-eeeeeeeeeeee")!
        let regularConversationID = UUID(uuidString: "eeeeeeee-1111-2222-3333-ffffffffffff")!

        store.replaceConversationSummaryWindow(
            [
                IMConversationSummaryResponseBody(
                    id: regularConversationID,
                    title: "Regular",
                    memberUserIDs: [Self.currentUserID, Self.peerUserID],
                    lastMessage: IMMessagePreviewResponseBody(
                        id: UUID(),
                        senderUserID: Self.peerUserID,
                        serverSequence: 8,
                        timelineSequence: 8,
                        content: .richText(.plain("regular preview")),
                        createdAt: Date(timeIntervalSince1970: 1_700_410_100)
                    ),
                    lastReadSequence: 5,
                    unreadCount: 3,
                    createdAt: Date(timeIntervalSince1970: 1_700_410_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_410_100)
                ),
                IMConversationSummaryResponseBody(
                    id: mutedPinnedConversationID,
                    title: "Pinned",
                    memberUserIDs: [Self.currentUserID, Self.peerUserID],
                    lastMessage: IMMessagePreviewResponseBody(
                        id: UUID(),
                        senderUserID: Self.peerUserID,
                        serverSequence: 4,
                        timelineSequence: 4,
                        content: .richText(.plain("muted preview")),
                        createdAt: Date(timeIntervalSince1970: 1_700_410_050)
                    ),
                    lastReadSequence: 0,
                    unreadCount: 4,
                    isPinned: true,
                    pinnedAt: Date(timeIntervalSince1970: 1_700_410_200),
                    isMuted: true,
                    createdAt: Date(timeIntervalSince1970: 1_700_410_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_410_050)
                )
            ],
            nextCursor: nil,
            hasMore: false
        )

        #expect(store.conversations.map(\.id) == [
            mutedPinnedConversationID.uuidString,
            regularConversationID.uuidString
        ])
        #expect(store.conversations[0].unreadCount == 4)
        #expect(store.conversations[0].isMuted == true)
        #expect(store.totalUnreadCount == 3)
    }

    @Test func draftAndSearchStateStayLocalAndDraftClearsOnSend() {
        let store = IMConversationStore()
        let matchingConversationID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let otherConversationID = UUID(uuidString: "66666666-7777-8888-9999-aaaaaaaaaaaa")!

        store.replaceConversationSummaryWindow(
            [
                IMConversationSummaryResponseBody(
                    id: matchingConversationID,
                    title: "iOS Study Group",
                    memberUserIDs: [Self.currentUserID, Self.peerUserID],
                    notice: "Weekly architecture review",
                    lastMessage: IMMessagePreviewResponseBody(
                        id: UUID(),
                        senderUserID: Self.peerUserID,
                        serverSequence: 2,
                        timelineSequence: 2,
                        content: .richText(.plain("sync notes")),
                        createdAt: Date(timeIntervalSince1970: 1_700_420_100)
                    ),
                    createdAt: Date(timeIntervalSince1970: 1_700_420_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_420_100)
                ),
                IMConversationSummaryResponseBody(
                    id: otherConversationID,
                    title: "Random Chat",
                    memberUserIDs: [Self.currentUserID, Self.peerUserID],
                    lastMessage: IMMessagePreviewResponseBody(
                        id: UUID(),
                        senderUserID: Self.peerUserID,
                        serverSequence: 1,
                        timelineSequence: 1,
                        content: .richText(.plain("lunch?")),
                        createdAt: Date(timeIntervalSince1970: 1_700_420_050)
                    ),
                    createdAt: Date(timeIntervalSince1970: 1_700_420_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_420_050)
                )
            ],
            nextCursor: nil,
            hasMore: false
        )

        store.updateDraft("Need to send agenda", for: matchingConversationID.uuidString)
        #expect(store.draftText(for: matchingConversationID.uuidString) == "Need to send agenda")

        store.setConversationSearchText("architecture")
        #expect(store.filteredConversations.map(\.id) == [matchingConversationID.uuidString])

        let request = store.prepareOutgoingText(
            "Need to send agenda",
            conversationID: matchingConversationID.uuidString,
            senderUserID: Self.currentUserID
        )

        #expect(request != nil)
        #expect(store.draftText(for: matchingConversationID.uuidString).isEmpty)
    }

    @Test func asyncDraftUpdateUsesClientStateEngineAndProjectsMainActorState() async {
        let store = IMConversationStore()
        let conversationID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

        store.replaceConversationSummaries(
            [
                IMConversationSummaryResponseBody(
                    id: conversationID,
                    title: "Draft",
                    memberUserIDs: [Self.currentUserID, Self.peerUserID],
                    lastMessage: nil,
                    createdAt: Date(timeIntervalSince1970: 1_700_420_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_420_100)
                )
            ]
        )

        await store.updateDraftAsync("Need to send agenda", for: conversationID.uuidString)
        #expect(store.draftText(for: conversationID.uuidString) == "Need to send agenda")
        #expect(store.conversations.first?.draftUpdatedAt != nil)

        await store.updateDraftAsync("", for: conversationID.uuidString)
        #expect(store.draftText(for: conversationID.uuidString).isEmpty)
        #expect(store.conversations.first?.draftUpdatedAt == nil)
    }

    @Test func asyncStatusMessageUsesClientStateEngineAndProjectsMainActorState() async {
        let store = IMConversationStore()

        await store.setStatusMessageAsync("消息内容不能为空。")
        #expect(store.statusMessage == "消息内容不能为空。")

        await store.setStatusMessageAsync(nil)
        #expect(store.statusMessage == nil)
    }

    @Test func asyncLoadingStateUsesClientStateEngineAndProjectsMainActorState() async {
        let store = IMConversationStore()

        await store.setLoadingConversationsAsync(true)
        await store.setLoadingMoreConversationSummariesAsync(true)
        await store.setLoadingMembersAsync(true)
        await store.setLoadingMessagesAsync(true)

        #expect(store.isLoadingConversations)
        #expect(store.isLoadingMoreConversationSummaries)
        #expect(store.isLoadingMembers)
        #expect(store.isLoadingMessages)

        await store.setLoadingConversationsAsync(false)
        await store.setLoadingMoreConversationSummariesAsync(false)
        await store.setLoadingMembersAsync(false)
        await store.setLoadingMessagesAsync(false)

        #expect(!store.isLoadingConversations)
        #expect(!store.isLoadingMoreConversationSummaries)
        #expect(!store.isLoadingMembers)
        #expect(!store.isLoadingMessages)
    }

    @Test func resetProjectsEmptyClientSnapshotAndAdvancesMutationGeneration() {
        let store = IMConversationStore()
        let conversationID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

        store.replaceConversationSummaryWindow(
            [
                IMConversationSummaryResponseBody(
                    id: conversationID,
                    title: "Reset Target",
                    memberUserIDs: [Self.currentUserID, Self.peerUserID],
                    lastMessage: nil,
                    createdAt: Date(timeIntervalSince1970: 1_700_420_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_420_100)
                )
            ],
            nextCursor: "next-page",
            hasMore: true
        )
        store.openConversation(id: conversationID.uuidString)
        store.setStatusMessage("stale status")
        store.setLoadingConversations(true)
        store.setLoadingMoreConversationSummaries(true)
        store.setLoadingMembers(true)
        store.setLoadingMessages(true)
        store.setConversationSearchText("reset")
        let generation = store.conversationMutationGeneration

        store.reset()

        #expect(store.conversations.isEmpty)
        #expect(store.selectedConversationID == nil)
        #expect(store.statusMessage == nil)
        #expect(!store.isLoadingConversations)
        #expect(store.conversationSummaryNextCursor == nil)
        #expect(!store.hasMoreConversationSummaries)
        #expect(!store.isLoadingMoreConversationSummaries)
        #expect(!store.isLoadingMembers)
        #expect(!store.isLoadingMessages)
        #expect(store.searchText.isEmpty)
        #expect(store.replyJumpState == .idle)
        #expect(store.conversationMutationGeneration == generation + 1)
    }

    @Test func replaceConversationSummariesStoresDirectMessagingState() {
        let store = IMConversationStore()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!

        store.replaceConversationSummaries(
            [
                IMConversationSummaryResponseBody(
                    id: conversationID,
                    title: nil,
                    kind: IMConversationKind.direct.rawValue,
                    directMessagingState: IMDirectMessagingState.frozenAfterUnfriend.rawValue,
                    directPeer: IMDirectPeerResponseBody(id: Self.peerUserID, email: "peer@example.com"),
                    memberCount: 2,
                    memberUserIDs: [Self.currentUserID, Self.peerUserID],
                    lastMessage: nil,
                    createdAt: Date(timeIntervalSince1970: 1_700_200_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_200_000)
                )
            ]
        )

        #expect(store.selectedConversation?.directMessagingState == .frozenAfterUnfriend)
        #expect(store.selectedConversation?.directPeer == IMDirectPeer(id: Self.peerUserID, email: "peer@example.com"))
        #expect(store.selectedConversation?.title == "peer@example.com")
        #expect(store.selectedConversation?.isDirectMessagingFrozen == true)
        #expect(store.selectedConversation?.canSendMessages == false)
        #expect(store.selectedConversation?.directMessagingStatusMessage == "你们已不是好友，当前会话不能继续发送消息。")
    }

    @Test func directConversationWithoutDirectMessagingStateDefaultsToActive() {
        let store = IMConversationStore()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!

        store.replaceConversationSummaries(
            [
                IMConversationSummaryResponseBody(
                    id: conversationID,
                    title: nil,
                    kind: IMConversationKind.direct.rawValue,
                    memberCount: 2,
                    memberUserIDs: [Self.currentUserID, Self.peerUserID],
                    lastMessage: nil,
                    createdAt: Date(timeIntervalSince1970: 1_700_200_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_200_000)
                )
            ]
        )

        #expect(store.selectedConversation?.directMessagingState == .active)
        #expect(store.selectedConversation?.canSendMessages == true)
        #expect(store.selectedConversation?.isDirectMessagingFrozen == false)
    }

    @Test func replaceConversationSummariesImportsFrozenGroupLifecycle() {
        let store = IMConversationStore()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!

        store.replaceConversationSummaries(
            [
                IMConversationSummaryResponseBody(
                    id: conversationID,
                    title: "Frozen Group",
                    kind: IMConversationKind.group.rawValue,
                    groupLifecycleState: IMGroupLifecycleState.frozen.rawValue,
                    memberCount: 3,
                    memberUserIDs: [Self.currentUserID, Self.peerUserID],
                    lastMessage: nil,
                    createdAt: Date(timeIntervalSince1970: 1_700_200_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_200_000)
                )
            ]
        )

        #expect(store.selectedConversation?.groupLifecycleState == .frozen)
        #expect(store.selectedConversation?.isGroupFrozen == true)
        #expect(store.selectedConversation?.canSendMessages == false)
        #expect(store.selectedConversation?.groupLifecycleStatusMessage == "群聊已被冻结，当前只能查看历史消息。")
    }

    @Test func replaceConversationSummariesImportsDissolvedGroupLifecycle() {
        let store = IMConversationStore()
        let conversationID = UUID(uuidString: "bbbbbbbb-1111-2222-3333-cccccccccccc")!

        store.replaceConversationSummaries(
            [
                IMConversationSummaryResponseBody(
                    id: conversationID,
                    title: "Dissolved Group",
                    kind: IMConversationKind.group.rawValue,
                    groupLifecycleState: IMGroupLifecycleState.dissolved.rawValue,
                    memberCount: 3,
                    memberUserIDs: [Self.currentUserID, Self.peerUserID],
                    lastMessage: nil,
                    createdAt: Date(timeIntervalSince1970: 1_700_200_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_200_000)
                )
            ]
        )

        #expect(store.selectedConversation?.groupLifecycleState == .dissolved)
        #expect(store.selectedConversation?.isGroupDissolved == true)
        #expect(store.selectedConversation?.isGroupReadOnly == true)
        #expect(store.selectedConversation?.canSendMessages == false)
        #expect(store.selectedConversation?.groupLifecycleStatusMessage == "群聊已解散，消息记录保留为只读。")
    }

    @Test func groupConversationIgnoresDirectMessagingState() {
        let store = IMConversationStore()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!

        store.replaceConversationSummaries(
            [
                IMConversationSummaryResponseBody(
                    id: conversationID,
                    title: "Group",
                    kind: IMConversationKind.group.rawValue,
                    directMessagingState: IMDirectMessagingState.frozenAfterUnfriend.rawValue,
                    memberCount: 3,
                    memberUserIDs: [Self.currentUserID, Self.peerUserID],
                    lastMessage: nil,
                    createdAt: Date(timeIntervalSince1970: 1_700_200_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_200_000)
                )
            ]
        )

        #expect(store.selectedConversation?.directMessagingState == nil)
        #expect(store.selectedConversation?.canSendMessages == true)
        #expect(store.selectedConversation?.isDirectMessagingFrozen == false)
    }

    @Test func replaceConversationSummariesPreservesUnreadCounts() {
        let store = IMConversationStore()
        let selectedConversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let backgroundConversationID = UUID(uuidString: "bbbbbbbb-1111-2222-3333-cccccccccccc")!

        store.replaceConversationSummaries(
            [
                IMConversationSummaryResponseBody(
                    id: selectedConversationID,
                    title: "selected",
                    memberUserIDs: [Self.currentUserID, Self.peerUserID],
                    lastMessage: nil,
                    createdAt: Date(timeIntervalSince1970: 1_700_200_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_200_000)
                ),
                IMConversationSummaryResponseBody(
                    id: backgroundConversationID,
                    title: "background",
                    memberUserIDs: [Self.currentUserID, Self.peerUserID],
                    lastMessage: nil,
                    createdAt: Date(timeIntervalSince1970: 1_700_200_001),
                    updatedAt: Date(timeIntervalSince1970: 1_700_200_001)
                )
            ]
        )

        store.applyTestDomainMessage(
            IMTCPMessagePayload(
                clientMessageID: nil,
                messageID: "srv-unread-1",
                conversationID: backgroundConversationID.uuidString,
                senderUserID: Self.peerUserID,
                serverSequence: 10,
                serverTimestamp: Date(timeIntervalSince1970: 1_700_300_000),
                kind: "rich_text",
                body: ["text": "live unread"]
            ),
            currentUserID: Self.currentUserID
        )

        store.replaceConversationSummaries(
            [
                IMConversationSummaryResponseBody(
                    id: backgroundConversationID,
                    title: "background",
                    memberUserIDs: [Self.currentUserID, Self.peerUserID],
                    lastMessage: IMMessagePreviewResponseBody(
                        id: UUID(uuidString: "dddddddd-1111-2222-3333-eeeeeeeeeeee")!,
                        senderUserID: Self.peerUserID,
                        serverSequence: 10,
                        kind: "rich_text",
                        body: ["text": "server preview"],
                        createdAt: Date(timeIntervalSince1970: 1_700_300_000)
                    ),
                    createdAt: Date(timeIntervalSince1970: 1_700_200_001),
                    updatedAt: Date(timeIntervalSince1970: 1_700_300_000)
                ),
                IMConversationSummaryResponseBody(
                    id: selectedConversationID,
                    title: "selected",
                    memberUserIDs: [Self.currentUserID, Self.peerUserID],
                    lastMessage: nil,
                    createdAt: Date(timeIntervalSince1970: 1_700_200_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_200_000)
                )
            ]
        )

        let unreadConversation = store.conversations.first { $0.id == backgroundConversationID.uuidString }
        #expect(store.selectedConversationID == selectedConversationID.uuidString)
        #expect(unreadConversation?.unreadCount == 1)
        #expect(store.totalUnreadCount == 1)
    }


}
