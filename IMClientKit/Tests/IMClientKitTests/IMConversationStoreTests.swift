import Foundation
import Testing
@testable import IMClientKit

@MainActor
struct IMConversationStoreTests {
    static let currentUserID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    static let peerUserID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    static func gapSummary(
        conversationID: UUID,
        latestServerSequence: Int?
    ) -> IMConversationSummaryResponseBody {
        let updatedAt = latestServerSequence.map {
            Date(timeIntervalSince1970: 1_700_400_000 + Double($0))
        } ?? Date(timeIntervalSince1970: 1_700_400_000)

        return IMConversationSummaryResponseBody(
            id: conversationID,
            title: nil,
            kind: IMConversationKind.direct.rawValue,
            memberCount: 2,
            memberUserIDs: [Self.currentUserID, Self.peerUserID],
            lastMessage: latestServerSequence.map { sequence in
                IMMessagePreviewResponseBody(
                    id: UUID(),
                    senderUserID: Self.peerUserID,
                    serverSequence: UInt64(sequence),
                    kind: "rich_text",
                    body: ["text": "summary \(sequence)"],
                    createdAt: updatedAt
                )
            },
            createdAt: Date(timeIntervalSince1970: 1_700_300_000),
            updatedAt: updatedAt
        )
    }

    static func messageResponse(
        conversationID: UUID,
        serverSequence: Int
    ) -> IMConversationMessageResponseBody {
        IMConversationMessageResponseBody(
            id: UUID(),
            conversationID: conversationID,
            senderUserID: Self.peerUserID,
            clientMessageID: nil,
            serverSequence: UInt64(serverSequence),
            kind: "rich_text",
            body: ["text": "local \(serverSequence)"],
            createdAt: Date(timeIntervalSince1970: 1_700_500_000 + Double(serverSequence))
        )
    }

    static func cachedQueuedMessage(
        id: String,
        conversationID: String,
        text: String,
        createdAt: TimeInterval
    ) -> IMCachedPendingMessageState {
        IMCachedPendingMessageState(
            localMessageID: id,
            clientMessageID: id,
            conversationID: conversationID,
            senderUserID: Self.currentUserID,
            content: testMessageContent(kind: "rich_text", body: ["text": text]),
            createdAt: Date(timeIntervalSince1970: createdAt),
            deliveryState: .queued(message: "等待 IM 长连接恢复后发送。")
        )
    }

    @Test func replaceConversationSummariesOnlyCorrectsPreviewAndOrdering() {
        let store = IMConversationStore()
        let conversationID = UUID(uuidString: "bbbbbbbb-1111-2222-3333-cccccccccccc")!

        store.replaceConversationSummaries(
            [
                IMConversationSummaryResponseBody(
                    id: conversationID,
                    title: "before",
                    memberUserIDs: [Self.currentUserID, Self.peerUserID],
                    lastMessage: IMMessagePreviewResponseBody(
                        id: UUID(uuidString: "cccccccc-1111-2222-3333-dddddddddddd")!,
                        senderUserID: Self.peerUserID,
                        serverSequence: 3,
                        kind: "rich_text",
                        body: ["text": "old preview"],
                        createdAt: Date(timeIntervalSince1970: 1_700_300_000)
                    ),
                    createdAt: Date(timeIntervalSince1970: 1_700_200_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_300_000)
                )
            ]
        )
        store.applyServerSummaryReadState(
            lastReadSequence: 8,
            unreadCount: 2,
            for: conversationID.uuidString
        )

        store.replaceConversationSummaries(
            [
                IMConversationSummaryResponseBody(
                    id: conversationID,
                    title: "after",
                    memberUserIDs: [Self.currentUserID, Self.peerUserID],
                    lastMessage: IMMessagePreviewResponseBody(
                        id: UUID(uuidString: "dddddddd-1111-2222-3333-eeeeeeeeeeee")!,
                        senderUserID: Self.peerUserID,
                        serverSequence: 9,
                        kind: "rich_text",
                        body: ["text": "new preview"],
                        createdAt: Date(timeIntervalSince1970: 1_700_300_100)
                    ),
                    lastReadSequence: 1,
                    unreadCount: 7,
                    createdAt: Date(timeIntervalSince1970: 1_700_200_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_300_100)
                )
            ]
        )

        let conversation = store.selectedConversation
        #expect(conversation?.title == "after")
        #expect(conversation?.lastMessagePreview == "new preview")
        #expect(conversation?.updatedAt == Date(timeIntervalSince1970: 1_700_300_100))
        #expect(conversation?.serverLastReadSequence == 1)
        #expect(conversation?.serverUnreadCount == 7)
    }


    @Test func conversationCreatedEventUpsertsSummaryUsingAuthoritativeReadState() {
        let store = IMConversationStore()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!

        let outcome = store.applyTestConversationEvent(
            TestConversationEventPayload(
                eventType: .conversationCreated,
                conversation: IMConversationSummaryResponseBody(
                    id: conversationID,
                    title: "New Group",
                    kind: IMConversationKind.group.rawValue,
                    memberCount: 3,
                    memberUserIDs: [Self.currentUserID, Self.peerUserID],
                    lastMessage: nil,
                    lastReadSequence: 12,
                    unreadCount: 4,
                    createdAt: Date(timeIntervalSince1970: 1_700_200_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_300_000)
                ),
                actorUserID: Self.peerUserID,
                serverTimestamp: Date(timeIntervalSince1970: 1_700_300_001)
            ),
            currentUserID: Self.currentUserID
        )

        let conversation = store.selectedConversation
        #expect(outcome.shouldReloadMembersForConversationID == nil)
        #expect(conversation?.id == conversationID.uuidString)
        #expect(conversation?.title == "New Group")
        #expect(conversation?.kind == .group)
        #expect(conversation?.memberCount == 3)
        #expect(conversation?.serverLastReadSequence == 12)
        #expect(conversation?.serverUnreadCount == 4)
        #expect(conversation?.localUnreadDelta == 0)
    }

    @Test func asyncDomainEventAppliesSummaryNoticeAndConsumedStateThroughClientStateEngine() async throws {
        let store = IMConversationStore()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let noticeID = UUID(uuidString: "bbbbbbbb-1111-2222-3333-cccccccccccc")!
        let eventID = UUID(uuidString: "cccccccc-1111-2222-3333-dddddddddddd")!
        let occurredAt = Date(timeIntervalSince1970: 1_700_300_001)

        let outcome = await store.applyDomainEventAsync(
            IMTCPChatDomainEventPayload(
                eventID: eventID,
                eventType: .conversationUpdated,
                aggregateType: "conversation",
                aggregateID: conversationID,
                aggregateSequence: 3,
                occurredAt: occurredAt,
                actorUserID: Self.peerUserID,
                conversation: IMConversationSummaryResponseBody(
                    id: conversationID,
                    title: "Async Group",
                    kind: IMConversationKind.group.rawValue,
                    memberCount: 2,
                    memberUserIDs: [Self.currentUserID, Self.peerUserID],
                    lastMessage: nil,
                    lastReadSequence: 5,
                    unreadCount: 2,
                    createdAt: Date(timeIntervalSince1970: 1_700_200_000),
                    updatedAt: occurredAt
                ),
                timelineNotice: IMTimelineNoticeResponseBody(
                    id: noticeID,
                    conversationID: conversationID,
                    timelineSequence: 4,
                    eventType: "conversation.updated",
                    actorUserID: Self.peerUserID,
                    targetUserIDs: [],
                    noticeKind: "conversation_updated",
                    params: [:],
                    fallbackText: "Conversation updated",
                    createdAt: occurredAt
                ),
                body: .conversationChanged
            ),
            currentUserID: Self.currentUserID
        )

        let conversation = try #require(store.selectedConversation)
        #expect(!outcome.shouldFetchDomainEvents)
        #expect(outcome.didConsumeEvent)
        #expect(conversation.id == conversationID.uuidString)
        #expect(conversation.title == "Async Group")
        #expect(conversation.serverLastReadSequence == 5)
        #expect(conversation.serverUnreadCount == 2)
        #expect(conversation.notices.map(\.id) == [noticeID.uuidString])
        #expect(conversation.notices.first?.fallbackText == "Conversation updated")
    }

    @Test func duplicateTCPDomainEventIsAppliedOnce() async throws {
        let store = IMConversationStore()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let noticeID = UUID(uuidString: "bbbbbbbb-1111-2222-3333-cccccccccccc")!
        let eventID = UUID(uuidString: "cccccccc-1111-2222-3333-dddddddddddd")!
        let occurredAt = Date(timeIntervalSince1970: 1_700_300_001)
        let payload = IMTCPChatDomainEventPayload(
            eventID: eventID,
            eventType: .conversationUpdated,
            aggregateType: "conversation",
            aggregateID: conversationID,
            aggregateSequence: 3,
            occurredAt: occurredAt,
            actorUserID: Self.peerUserID,
            conversation: IMConversationSummaryResponseBody(
                id: conversationID,
                title: "Async Group",
                kind: IMConversationKind.group.rawValue,
                memberCount: 2,
                memberUserIDs: [Self.currentUserID, Self.peerUserID],
                lastMessage: nil,
                lastReadSequence: 5,
                unreadCount: 2,
                createdAt: Date(timeIntervalSince1970: 1_700_200_000),
                updatedAt: occurredAt
            ),
            timelineNotice: IMTimelineNoticeResponseBody(
                id: noticeID,
                conversationID: conversationID,
                timelineSequence: 4,
                eventType: "conversation.updated",
                actorUserID: Self.peerUserID,
                targetUserIDs: [],
                noticeKind: "conversation_updated",
                params: [:],
                fallbackText: "Conversation updated",
                createdAt: occurredAt
            ),
            body: .conversationChanged
        )

        _ = await store.applyDomainEventAsync(payload, currentUserID: Self.currentUserID)
        _ = await store.applyDomainEventAsync(payload, currentUserID: Self.currentUserID)

        let conversation = try #require(store.selectedConversation)
        let snapshot = store.makeCacheSnapshot(lastSummaryRefreshAt: nil)
        #expect(conversation.notices.map(\.id) == [noticeID.uuidString])
        #expect(snapshot.domainEventState.appliedEventIDs == [eventID])
    }

    @Test func lightweightConversationUpdateRequestsSummaryRefresh() async {
        let store = IMConversationStore()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!

        let outcome = await store.applyDomainEventAsync(
            IMTCPChatDomainEventPayload(
                eventID: UUID(uuidString: "dddddddd-1111-2222-3333-eeeeeeeeeeee")!,
                eventType: .conversationUpdated,
                aggregateType: "conversation",
                aggregateID: conversationID,
                aggregateSequence: 1,
                occurredAt: Date(timeIntervalSince1970: 1_700_300_002),
                actorUserID: Self.peerUserID,
                conversation: nil,
                ownerCursor: 1,
                ownerAggregateSequence: 1,
                body: .conversationChanged
            ),
            currentUserID: Self.currentUserID
        )

        #expect(!outcome.shouldFetchDomainEvents)
        #expect(outcome.shouldRefreshConversationSummaries)
        #expect(outcome.didConsumeEvent)
    }

    @Test func activityOnlyConversationHintUpdatesListWithoutOverwritingReadState() async throws {
        let store = IMConversationStore()
        let selectedConversationID = UUID(uuidString: "aaaaaaaa-0000-0000-0000-bbbbbbbbbbbb")!
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let messageID = UUID(uuidString: "eeeeeeee-1111-2222-3333-ffffffffffff")!
        let baselineDate = Date(timeIntervalSince1970: 1_700_300_000)
        let hintDate = Date(timeIntervalSince1970: 1_700_300_010)

        store.replaceConversationSummaries(
            [
                IMConversationSummaryResponseBody(
                    id: selectedConversationID,
                    title: "Selected",
                    memberUserIDs: [Self.currentUserID],
                    lastMessage: nil,
                    createdAt: baselineDate,
                    updatedAt: baselineDate
                ),
                IMConversationSummaryResponseBody(
                    id: conversationID,
                    title: "Large Group",
                    memberUserIDs: [Self.currentUserID, Self.peerUserID],
                    lastMessage: IMMessagePreviewResponseBody(
                        id: UUID(uuidString: "eeeeeeee-0000-0000-0000-ffffffffffff")!,
                        senderUserID: Self.peerUserID,
                        serverSequence: 7,
                        timelineSequence: 7,
                        content: .richText(.plain("old")),
                        createdAt: baselineDate
                    ),
                    lastReadSequence: 3,
                    unreadCount: 4,
                    createdAt: baselineDate,
                    updatedAt: baselineDate
                )
            ]
        )

        let outcome = await store.applyDomainEventAsync(
            IMTCPChatDomainEventPayload(
                eventID: UUID(uuidString: "dddddddd-2222-3333-4444-eeeeeeeeeeee")!,
                eventType: .conversationActivityHint,
                aggregateType: "conversation",
                aggregateID: conversationID,
                aggregateSequence: 8,
                occurredAt: hintDate,
                actorUserID: Self.peerUserID,
                conversation: nil,
                body: .conversationActivityHint(
                    IMConversationActivityHintResponseBody(
                        messageID: messageID,
                        senderUserID: Self.peerUserID,
                        serverSequence: 8,
                        timelineSequence: 8,
                        previewText: "new hint",
                        messageCreatedAt: hintDate,
                        updatedAt: hintDate
                    )
                )
            ),
            currentUserID: Self.currentUserID
        )

        let conversation = try #require(store.conversations.first { $0.id == conversationID.uuidString })
        #expect(outcome.didConsumeEvent)
        #expect(!outcome.shouldRefreshConversationSummaries)
        #expect(outcome.shouldSyncTimelineForConversationID == nil)
        #expect(outcome.timelineSyncTargetSequence == nil)
        #expect(conversation.title == "Large Group")
        #expect(conversation.memberUserIDs == [Self.currentUserID, Self.peerUserID].sorted { $0.uuidString < $1.uuidString })
        #expect(conversation.messages.isEmpty)
        #expect(conversation.lastMessagePreviewText == "new hint")
        #expect(conversation.serverLastReadSequence == 3)
        #expect(conversation.serverUnreadCount == 4)
        #expect(conversation.localUnreadDelta == 1)
        #expect(conversation.unreadCount == 5)
    }

    @Test func selectedActivityOnlyConversationHintRequestsTimelineSync() async throws {
        let store = IMConversationStore()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let messageID = UUID(uuidString: "eeeeeeee-1111-2222-3333-ffffffffffff")!
        let baselineDate = Date(timeIntervalSince1970: 1_700_300_000)
        let hintDate = Date(timeIntervalSince1970: 1_700_300_010)

        store.replaceConversationSummaries(
            [
                IMConversationSummaryResponseBody(
                    id: conversationID,
                    title: "Large Group",
                    memberUserIDs: [Self.currentUserID, Self.peerUserID],
                    lastMessage: IMMessagePreviewResponseBody(
                        id: UUID(uuidString: "eeeeeeee-0000-0000-0000-ffffffffffff")!,
                        senderUserID: Self.peerUserID,
                        serverSequence: 7,
                        timelineSequence: 7,
                        content: .richText(.plain("old")),
                        createdAt: baselineDate
                    ),
                    lastReadSequence: 7,
                    unreadCount: 0,
                    createdAt: baselineDate,
                    updatedAt: baselineDate
                )
            ]
        )
        store.openConversation(id: conversationID.uuidString)

        let outcome = await store.applyDomainEventAsync(
            IMTCPChatDomainEventPayload(
                eventID: UUID(uuidString: "dddddddd-2222-3333-4444-eeeeeeeeeeee")!,
                eventType: .conversationActivityHint,
                aggregateType: "conversation",
                aggregateID: conversationID,
                aggregateSequence: 8,
                occurredAt: hintDate,
                actorUserID: Self.peerUserID,
                conversation: nil,
                body: .conversationActivityHint(
                    IMConversationActivityHintResponseBody(
                        messageID: messageID,
                        senderUserID: Self.peerUserID,
                        serverSequence: 8,
                        timelineSequence: 8,
                        previewText: "new hint",
                        messageCreatedAt: hintDate,
                        updatedAt: hintDate
                    )
                )
            ),
            currentUserID: Self.currentUserID
        )

        #expect(outcome.didConsumeEvent)
        #expect(outcome.shouldSyncTimelineForConversationID == conversationID.uuidString)
        #expect(outcome.timelineSyncTargetSequence == 8)
        #expect(!outcome.shouldFetchDomainEvents)
        #expect(!outcome.shouldRefreshConversationSummaries)
        #expect(store.selectedConversationID == conversationID.uuidString)
        #expect(store.conversations.first { $0.id == conversationID.uuidString }?.lastMessagePreviewText == "new hint")
        #expect(store.conversations.first { $0.id == conversationID.uuidString }?.messages.isEmpty == true)
    }

    @Test func selectedEmptyPreviewActivityHintOnlyRequestsTimelineSync() async throws {
        let store = IMConversationStore()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let messageID = UUID(uuidString: "eeeeeeee-1111-2222-3333-ffffffffffff")!
        let baselineDate = Date(timeIntervalSince1970: 1_700_300_000)
        let hintDate = Date(timeIntervalSince1970: 1_700_300_010)

        store.replaceConversationSummaries(
            [
                IMConversationSummaryResponseBody(
                    id: conversationID,
                    title: "Large Group",
                    memberUserIDs: [Self.currentUserID, Self.peerUserID],
                    lastMessage: IMMessagePreviewResponseBody(
                        id: UUID(uuidString: "eeeeeeee-0000-0000-0000-ffffffffffff")!,
                        senderUserID: Self.peerUserID,
                        serverSequence: 7,
                        timelineSequence: 7,
                        content: .richText(.plain("old")),
                        createdAt: baselineDate
                    ),
                    lastReadSequence: 7,
                    unreadCount: 0,
                    createdAt: baselineDate,
                    updatedAt: baselineDate
                )
            ]
        )
        store.openConversation(id: conversationID.uuidString)

        let outcome = await store.applyDomainEventAsync(
            IMTCPChatDomainEventPayload(
                eventID: UUID(uuidString: "dddddddd-2222-3333-4444-eeeeeeeeeeee")!,
                eventType: .conversationActivityHint,
                aggregateType: "conversation",
                aggregateID: conversationID,
                aggregateSequence: 8,
                occurredAt: hintDate,
                actorUserID: Self.peerUserID,
                conversation: nil,
                body: .conversationActivityHint(
                    IMConversationActivityHintResponseBody(
                        messageID: messageID,
                        senderUserID: Self.peerUserID,
                        serverSequence: 8,
                        timelineSequence: 8,
                        previewText: "",
                        messageCreatedAt: hintDate,
                        updatedAt: hintDate
                    )
                )
            ),
            currentUserID: Self.currentUserID
        )

        let conversation = try #require(store.conversations.first { $0.id == conversationID.uuidString })
        #expect(outcome.didConsumeEvent)
        #expect(outcome.shouldSyncTimelineForConversationID == conversationID.uuidString)
        #expect(outcome.timelineSyncTargetSequence == 8)
        #expect(!outcome.shouldFetchDomainEvents)
        #expect(!outcome.shouldRefreshConversationSummaries)
        #expect(conversation.lastMessagePreviewText == "old")
        #expect(conversation.updatedAt == baselineDate)
        #expect(conversation.unreadCount == 0)
        #expect(conversation.messages.isEmpty)
    }

    @Test func emptyPreviewActivityHintDoesNotOverwriteUnselectedConversationSummary() async throws {
        let store = IMConversationStore()
        let selectedConversationID = UUID(uuidString: "aaaaaaaa-0000-0000-0000-bbbbbbbbbbbb")!
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let messageID = UUID(uuidString: "eeeeeeee-1111-2222-3333-ffffffffffff")!
        let baselineDate = Date(timeIntervalSince1970: 1_700_300_000)
        let hintDate = Date(timeIntervalSince1970: 1_700_300_010)

        store.replaceConversationSummaries(
            [
                IMConversationSummaryResponseBody(
                    id: selectedConversationID,
                    title: "Selected",
                    memberUserIDs: [Self.currentUserID],
                    lastMessage: nil,
                    createdAt: baselineDate,
                    updatedAt: baselineDate
                ),
                IMConversationSummaryResponseBody(
                    id: conversationID,
                    title: "Large Group",
                    memberUserIDs: [Self.currentUserID, Self.peerUserID],
                    lastMessage: IMMessagePreviewResponseBody(
                        id: UUID(uuidString: "eeeeeeee-0000-0000-0000-ffffffffffff")!,
                        senderUserID: Self.peerUserID,
                        serverSequence: 7,
                        timelineSequence: 7,
                        content: .richText(.plain("old")),
                        createdAt: baselineDate
                    ),
                    lastReadSequence: 3,
                    unreadCount: 4,
                    createdAt: baselineDate,
                    updatedAt: baselineDate
                )
            ]
        )
        store.openConversation(id: selectedConversationID.uuidString)

        let outcome = await store.applyDomainEventAsync(
            IMTCPChatDomainEventPayload(
                eventID: UUID(uuidString: "dddddddd-2222-3333-4444-eeeeeeeeeeee")!,
                eventType: .conversationActivityHint,
                aggregateType: "conversation",
                aggregateID: conversationID,
                aggregateSequence: 8,
                occurredAt: hintDate,
                actorUserID: Self.peerUserID,
                conversation: nil,
                body: .conversationActivityHint(
                    IMConversationActivityHintResponseBody(
                        messageID: messageID,
                        senderUserID: Self.peerUserID,
                        serverSequence: 8,
                        timelineSequence: 8,
                        previewText: "",
                        messageCreatedAt: hintDate,
                        updatedAt: hintDate
                    )
                )
            ),
            currentUserID: Self.currentUserID
        )

        let conversation = try #require(store.conversations.first { $0.id == conversationID.uuidString })
        #expect(outcome.didConsumeEvent)
        #expect(outcome.shouldSyncTimelineForConversationID == nil)
        #expect(outcome.timelineSyncTargetSequence == nil)
        #expect(!outcome.shouldFetchDomainEvents)
        #expect(!outcome.shouldRefreshConversationSummaries)
        #expect(conversation.lastMessagePreviewText == "old")
        #expect(conversation.updatedAt == baselineDate)
        #expect(conversation.serverUnreadCount == 4)
        #expect(conversation.localUnreadDelta == 0)
        #expect(conversation.unreadCount == 4)
        #expect(conversation.messages.isEmpty)
    }

    @Test func domainEventBatchAggregatesLightweightSummaryRefreshRequest() async {
        let store = IMConversationStore()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let messageID = UUID(uuidString: "eeeeeeee-1111-2222-3333-ffffffffffff")!
        let event = IMTCPChatDomainEventPayload(
            eventID: UUID(uuidString: "ffffffff-1111-2222-3333-aaaaaaaaaaaa")!,
            eventType: .messageCreated,
            aggregateType: "conversation",
            aggregateID: conversationID,
            aggregateSequence: 1,
            occurredAt: Date(timeIntervalSince1970: 1_700_300_003),
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
                    content: .richText(.plain("lightweight batch")),
                    createdAt: Date(timeIntervalSince1970: 1_700_300_003)
                ),
                clientMessageID: nil
            )
        )

        let outcome = await store.applyDomainEventsAsync(
            [
                SessionClient.IMDomainEventDeliveryEnvelope(
                    cursor: 1,
                    eventID: event.eventID,
                    ownerAggregateSequence: event.ownerAggregateSequence ?? 0,
                    eventPBBase64: "",
                    payload: event
                )
            ],
            nextCursor: 1,
            currentUserID: Self.currentUserID
        )

        #expect(!outcome.shouldFetchDomainEvents)
        #expect(outcome.shouldRefreshConversationSummaries)
        #expect(outcome.didConsumeEvent)
        #expect(store.domainEventSyncCursor == 1)
    }

    @Test func selectedCompactMessageCreatedDoesNotRequestSummaryRefresh() async throws {
        let store = IMConversationStore()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let messageID = UUID(uuidString: "eeeeeeee-1111-2222-3333-ffffffffffff")!

        store.replaceConversationSummaries(
            [
                Self.gapSummary(conversationID: conversationID, latestServerSequence: nil)
            ]
        )
        store.openConversation(id: conversationID.uuidString)

        let event = IMTCPChatDomainEventPayload(
            eventID: UUID(uuidString: "ffffffff-1111-2222-3333-aaaaaaaaaaaa")!,
            eventType: .messageCreated,
            aggregateType: "conversation",
            aggregateID: conversationID,
            aggregateSequence: 1,
            occurredAt: Date(timeIntervalSince1970: 1_700_300_003),
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
                    content: .richText(.plain("compact active")),
                    createdAt: Date(timeIntervalSince1970: 1_700_300_003)
                ),
                clientMessageID: nil
            )
        )

        let outcome = await store.applyDomainEventsAsync(
            [
                SessionClient.IMDomainEventDeliveryEnvelope(
                    cursor: 1,
                    eventID: event.eventID,
                    ownerAggregateSequence: event.ownerAggregateSequence ?? 0,
                    eventPBBase64: "",
                    payload: event
                )
            ],
            nextCursor: 1,
            currentUserID: Self.currentUserID
        )

        let selectedConversation = try #require(store.selectedConversation)
        #expect(outcome.didConsumeEvent)
        #expect(!outcome.shouldFetchDomainEvents)
        #expect(!outcome.shouldRefreshConversationSummaries)
        #expect(outcome.shouldSyncTimelineForConversationID == nil)
        #expect(selectedConversation.messages.map(\.serverMessageID) == [messageID.uuidString])
        #expect(selectedConversation.lastMessagePreviewText == "compact active")
        #expect(store.domainEventSyncCursor == 1)
    }


    @Test func summaryUpdatedEventClearsRealtimeUnreadDelta() {
        let store = IMConversationStore()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!

        store.replaceConversationSummaries(
            [
                IMConversationSummaryResponseBody(
                    id: conversationID,
                    title: "Server Conversation",
                    memberUserIDs: [Self.currentUserID, Self.peerUserID],
                    lastMessage: nil,
                    createdAt: Date(timeIntervalSince1970: 1_700_200_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_200_000)
                )
            ]
        )
        store.applyTestDomainMessage(
            IMTCPMessagePayload(
                clientMessageID: nil,
                messageID: "srv-msg-1",
                conversationID: conversationID.uuidString,
                senderUserID: Self.peerUserID,
                serverSequence: 2,
                serverTimestamp: Date(timeIntervalSince1970: 1_700_300_000),
                kind: "rich_text",
                body: ["text": "live unread"]
            ),
            currentUserID: Self.currentUserID
        )

        _ = store.applyTestConversationEvent(
            TestConversationEventPayload(
                eventType: .summaryUpdated,
                conversation: IMConversationSummaryResponseBody(
                    id: conversationID,
                    title: "Server Conversation",
                    memberUserIDs: [Self.currentUserID, Self.peerUserID],
                    lastMessage: IMMessagePreviewResponseBody(
                        id: UUID(uuidString: "dddddddd-1111-2222-3333-eeeeeeeeeeee")!,
                        senderUserID: Self.peerUserID,
                        serverSequence: 2,
                        kind: "rich_text",
                        body: ["text": "live unread"],
                        createdAt: Date(timeIntervalSince1970: 1_700_300_000)
                    ),
                    lastReadSequence: 0,
                    unreadCount: 1,
                    createdAt: Date(timeIntervalSince1970: 1_700_200_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_300_000)
                ),
                actorUserID: Self.peerUserID,
                serverTimestamp: Date(timeIntervalSince1970: 1_700_300_001)
            ),
            currentUserID: Self.currentUserID
        )

        let conversation = store.selectedConversation
        #expect(conversation?.serverUnreadCount == 1)
        #expect(conversation?.localUnreadDelta == 0)
        #expect(conversation?.unreadCount == 1)
    }


    @Test func messageRecalledEventUsesAuthoritativePreviewAndClearsRealtimeUnreadDelta() {
        let store = IMConversationStore()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let recalledMessageID = UUID(uuidString: "cccccccc-1111-2222-3333-dddddddddddd")!

        store.replaceConversationSummaries(
            [
                IMConversationSummaryResponseBody(
                    id: conversationID,
                    title: "Server Conversation",
                    memberUserIDs: [Self.currentUserID, Self.peerUserID],
                    lastMessage: nil,
                    createdAt: Date(timeIntervalSince1970: 1_700_200_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_200_000)
                )
            ]
        )
        store.applyTestDomainMessage(
            IMTCPMessagePayload(
                clientMessageID: nil,
                messageID: recalledMessageID.uuidString,
                conversationID: conversationID.uuidString,
                senderUserID: Self.peerUserID,
                serverSequence: 2,
                serverTimestamp: Date(timeIntervalSince1970: 1_700_300_000),
                kind: "rich_text",
                body: ["text": "live unread"]
            ),
            currentUserID: Self.currentUserID
        )

        _ = store.applyTestConversationEvent(
            TestConversationEventPayload(
                eventType: .messageRecalled,
                conversation: IMConversationSummaryResponseBody(
                    id: conversationID,
                    title: "Server Conversation",
                    memberUserIDs: [Self.currentUserID, Self.peerUserID],
                    lastMessage: IMMessagePreviewResponseBody(
                        id: recalledMessageID,
                        senderUserID: Self.peerUserID,
                        serverSequence: 2,
                        timelineSequence: 2,
                        content: .richText(.plain("stale local copy")),
                        derivedState: MessageDerivedState(recallState: .recalled),
                        createdAt: Date(timeIntervalSince1970: 1_700_300_000)
                    ),
                    lastReadSequence: 0,
                    unreadCount: 1,
                    createdAt: Date(timeIntervalSince1970: 1_700_200_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_300_001)
                ),
                message: IMConversationMessageResponseBody(
                    id: recalledMessageID,
                    conversationID: conversationID,
                    senderUserID: Self.peerUserID,
                    clientMessageID: nil,
                    serverSequence: 2,
                    timelineSequence: 2,
                    content: .richText(.plain("original text")),
                    derivedState: MessageDerivedState(recallState: .recalled),
                    createdAt: Date(timeIntervalSince1970: 1_700_300_000)
                ),
                actorUserID: Self.peerUserID,
                serverTimestamp: Date(timeIntervalSince1970: 1_700_300_001)
            ),
            currentUserID: Self.currentUserID
        )

        let conversation = store.selectedConversation
        #expect(conversation?.lastMessagePreview == "撤回了一条消息")
        #expect(conversation?.serverUnreadCount == 1)
        #expect(conversation?.localUnreadDelta == 0)
        #expect(conversation?.unreadCount == 1)
        #expect(conversation?.messages.last?.derivedState.recallState == .recalled)
    }


    @Test func summaryChangesPreferAuthoritativeRecalledPreviewOverLoadedStaleMessage() {
        let store = IMConversationStore()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let recalledMessageID = UUID(uuidString: "cccccccc-1111-2222-3333-dddddddddddd")!

        store.replaceConversationSummaries(
            [
                IMConversationSummaryResponseBody(
                    id: conversationID,
                    title: "Server Conversation",
                    memberUserIDs: [Self.currentUserID, Self.peerUserID],
                    lastMessage: IMMessagePreviewResponseBody(
                        id: recalledMessageID,
                        senderUserID: Self.peerUserID,
                        serverSequence: 2,
                        kind: "rich_text",
                        body: ["text": "stale local copy"],
                        createdAt: Date(timeIntervalSince1970: 1_700_300_000)
                    ),
                    createdAt: Date(timeIntervalSince1970: 1_700_200_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_300_000)
                )
            ]
        )
        store.openConversation(id: conversationID.uuidString)
        store.replaceTimelineItems(
            in: conversationID.uuidString,
            messages: [
                IMConversationMessageResponseBody(
                    id: recalledMessageID,
                    conversationID: conversationID,
                    senderUserID: Self.peerUserID,
                    clientMessageID: nil,
                    serverSequence: 2,
                    kind: "rich_text",
                    body: ["text": "stale local copy"],
                    createdAt: Date(timeIntervalSince1970: 1_700_300_000)
                )
            ],
            currentUserID: Self.currentUserID
        )

        store.applyConversationSummaryChanges(
            upserts: [
                IMConversationSummaryResponseBody(
                    id: conversationID,
                    title: "Server Conversation",
                    memberUserIDs: [Self.currentUserID, Self.peerUserID],
                    lastMessage: IMMessagePreviewResponseBody(
                        id: recalledMessageID,
                        senderUserID: Self.peerUserID,
                        serverSequence: 2,
                        timelineSequence: 2,
                        content: .richText(.plain("stale local copy")),
                        derivedState: MessageDerivedState(recallState: .recalled),
                        createdAt: Date(timeIntervalSince1970: 1_700_300_000)
                    ),
                    lastReadSequence: 0,
                    unreadCount: 1,
                    createdAt: Date(timeIntervalSince1970: 1_700_200_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_300_001)
                )
            ],
            removedConversationIDs: []
        )

        let conversation = store.selectedConversation
        #expect(conversation?.lastMessagePreview == "撤回了一条消息")
        #expect(conversation?.lastMessagePreviewText == "撤回了一条消息")
        #expect(conversation?.messages.last?.text == "stale local copy")
    }


    @Test func messageUpdatedEventUsesEditedDerivedStateForPreviewAndTimelineText() throws {
        let store = IMConversationStore()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let messageID = UUID(uuidString: "cccccccc-1111-2222-3333-dddddddddddd")!
        let createdAt = Date(timeIntervalSince1970: 1_700_300_000)

        store.replaceConversationSummaries(
            [
                IMConversationSummaryResponseBody(
                    id: conversationID,
                    title: "Server Conversation",
                    memberUserIDs: [Self.currentUserID, Self.peerUserID],
                    lastMessage: IMMessagePreviewResponseBody(
                        id: messageID,
                        senderUserID: Self.currentUserID,
                        serverSequence: 2,
                        timelineSequence: 2,
                        content: .richText(.plain("before edit")),
                        createdAt: createdAt
                    ),
                    createdAt: Date(timeIntervalSince1970: 1_700_200_000),
                    updatedAt: createdAt
                )
            ]
        )
        store.openConversation(id: conversationID.uuidString)
        store.replaceTimelineItems(
            in: conversationID.uuidString,
            messages: [
                IMConversationMessageResponseBody(
                    id: messageID,
                    conversationID: conversationID,
                    senderUserID: Self.currentUserID,
                    clientMessageID: "client-edit-1",
                    serverSequence: 2,
                    timelineSequence: 2,
                    content: .richText(.plain("before edit")),
                    createdAt: createdAt
                )
            ],
            currentUserID: Self.currentUserID
        )

        let editedState = IMMessageDerivedState(
            edits: [.init(editedAt: Date(timeIntervalSince1970: 1_700_300_100), body: .plain("after edit"))]
        )
        _ = store.applyTestConversationEvent(
            TestConversationEventPayload(
                eventType: .messageUpdated,
                conversation: IMConversationSummaryResponseBody(
                    id: conversationID,
                    title: "Server Conversation",
                    memberUserIDs: [Self.currentUserID, Self.peerUserID],
                    lastMessage: IMMessagePreviewResponseBody(
                        id: messageID,
                        senderUserID: Self.currentUserID,
                        serverSequence: 2,
                        timelineSequence: 2,
                        content: .richText(.plain("before edit")),
                        derivedState: editedState,
                        createdAt: createdAt
                    ),
                    createdAt: Date(timeIntervalSince1970: 1_700_200_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_300_100)
                ),
                message: IMConversationMessageResponseBody(
                    id: messageID,
                    conversationID: conversationID,
                    senderUserID: Self.currentUserID,
                    clientMessageID: "client-edit-1",
                    serverSequence: 2,
                    timelineSequence: 2,
                    content: .richText(.plain("before edit")),
                    derivedState: editedState,
                    createdAt: createdAt
                ),
                actorUserID: Self.currentUserID,
                serverTimestamp: Date(timeIntervalSince1970: 1_700_300_100)
            ),
            currentUserID: Self.currentUserID
        )

        let conversation = try #require(store.selectedConversation)
        let message = try #require(conversation.messages.last)
        #expect(conversation.lastMessagePreview == "after edit")
        #expect(message.text == "after edit")
        #expect(message.derivedState.edits.last?.body.text == "after edit")
    }

    @Test func messageStreamEventsMergeChunksIdempotentlyAndCompleteWithCanonicalMessage() throws {
        let store = IMConversationStore()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let messageID = UUID(uuidString: "cccccccc-1111-2222-3333-dddddddddddd")!
        let streamID = "stream-1"
        let createdAt = Date(timeIntervalSince1970: 1_700_300_000)

        store.replaceConversationSummaries(
            [
                IMConversationSummaryResponseBody(
                    id: conversationID,
                    title: "AI Conversation",
                    memberUserIDs: [Self.currentUserID, Self.peerUserID],
                    lastMessage: nil,
                    createdAt: Date(timeIntervalSince1970: 1_700_200_000),
                    updatedAt: createdAt
                )
            ]
        )
        store.openConversation(id: conversationID.uuidString)

        _ = store.applyTestConversationEvent(
            TestConversationEventPayload(
                eventType: .messageStreamStarted,
                conversation: IMConversationSummaryResponseBody(
                    id: conversationID,
                    title: "AI Conversation",
                    memberUserIDs: [Self.currentUserID, Self.peerUserID],
                    lastMessage: nil,
                    createdAt: Date(timeIntervalSince1970: 1_700_200_000),
                    updatedAt: createdAt
                ),
                message: IMConversationMessageResponseBody(
                    id: messageID,
                    conversationID: conversationID,
                    senderUserID: Self.currentUserID,
                    serverSequence: 2,
                    timelineSequence: 2,
                    content: .richText(.plain("")),
                    derivedState: IMMessageDerivedState(
                        streamState: MessageStreamState(
                            streamID: streamID,
                            state: .streaming,
                            updatedAt: createdAt
                        )
                    ),
                    createdAt: createdAt
                ),
                stream: IMTCPMessageStreamPayload(
                    streamID: streamID,
                    messageID: messageID.uuidString,
                    conversationID: conversationID.uuidString,
                    chunkIndex: 0,
                    partialTextLength: 0,
                    state: .streaming,
                    serverTimestamp: createdAt
                ),
                actorUserID: Self.currentUserID,
                serverTimestamp: createdAt
            ),
            currentUserID: Self.currentUserID
        )

        for chunk in [
            IMTCPMessageStreamPayload(
                streamID: streamID,
                messageID: messageID.uuidString,
                conversationID: conversationID.uuidString,
                chunkIndex: 1,
                deltaText: "AI",
                partialTextLength: 2,
                state: .streaming,
                serverTimestamp: Date(timeIntervalSince1970: 1_700_300_001)
            ),
            IMTCPMessageStreamPayload(
                streamID: streamID,
                messageID: messageID.uuidString,
                conversationID: conversationID.uuidString,
                chunkIndex: 1,
                deltaText: "AI",
                partialTextLength: 2,
                state: .streaming,
                serverTimestamp: Date(timeIntervalSince1970: 1_700_300_001)
            ),
            IMTCPMessageStreamPayload(
                streamID: streamID,
                messageID: messageID.uuidString,
                conversationID: conversationID.uuidString,
                chunkIndex: 2,
                deltaText: " response",
                partialTextLength: 11,
                state: .streaming,
                serverTimestamp: Date(timeIntervalSince1970: 1_700_300_002)
            )
        ] {
            store.applyStreamSignal(.init(stream: chunk), currentUserID: Self.currentUserID)
        }

        var conversation = try #require(store.selectedConversation)
        var message = try #require(conversation.messages.first)
        #expect(conversation.messages.count == 1)
        #expect(message.text == "AI response")
        #expect(message.derivedState.streamState?.lastChunkIndex == 2)
        #expect(store.activeMessageStreamTargets() == [
            IMActiveMessageStreamTarget(
                conversationID: conversationID.uuidString,
                messageID: messageID.uuidString,
                streamID: streamID
            )
        ])

        store.applyStreamSignal(
            .init(
                stream: IMTCPMessageStreamPayload(
                    streamID: streamID,
                    messageID: messageID.uuidString,
                    conversationID: conversationID.uuidString,
                    chunkIndex: 4,
                    deltaText: " gap",
                    partialTextLength: 15,
                    state: .streaming,
                    serverTimestamp: Date(timeIntervalSince1970: 1_700_300_004)
                )
            ),
            currentUserID: Self.currentUserID
        )
        #expect(store.selectedConversation?.messages.first?.text == "AI response")
        #expect(store.consumePendingStreamSnapshotTargets() == [
            IMActiveMessageStreamTarget(
                conversationID: conversationID.uuidString,
                messageID: messageID.uuidString,
                streamID: streamID
            )
        ])

        let completedAt = Date(timeIntervalSince1970: 1_700_300_003)
        let completedState = IMMessageDerivedState(
            streamState: MessageStreamState(
                streamID: streamID,
                state: .completed,
                lastChunkIndex: Int.max,
                partialText: "AI response",
                updatedAt: completedAt
            )
        )
        _ = store.applyTestConversationEvent(
            TestConversationEventPayload(
                eventType: .messageStreamCompleted,
                conversation: IMConversationSummaryResponseBody(
                    id: conversationID,
                    title: "AI Conversation",
                    memberUserIDs: [Self.currentUserID, Self.peerUserID],
                    lastMessage: IMMessagePreviewResponseBody(
                        id: messageID,
                        senderUserID: Self.currentUserID,
                        serverSequence: 2,
                        timelineSequence: 2,
                        content: .richText(.plain("AI response")),
                        derivedState: completedState,
                        createdAt: createdAt
                    ),
                    createdAt: Date(timeIntervalSince1970: 1_700_200_000),
                    updatedAt: completedAt
                ),
                message: IMConversationMessageResponseBody(
                    id: messageID,
                    conversationID: conversationID,
                    senderUserID: Self.currentUserID,
                    serverSequence: 2,
                    timelineSequence: 2,
                    content: .richText(.plain("AI response")),
                    derivedState: completedState,
                    createdAt: createdAt
                ),
                stream: IMTCPMessageStreamPayload(
                    streamID: streamID,
                    messageID: messageID.uuidString,
                    conversationID: conversationID.uuidString,
                    chunkIndex: Int.max,
                    partialTextLength: 11,
                    state: .completed,
                    serverTimestamp: completedAt
                ),
                actorUserID: Self.currentUserID,
                serverTimestamp: completedAt
            ),
            currentUserID: Self.currentUserID
        )

        conversation = try #require(store.selectedConversation)
        message = try #require(conversation.messages.first)
        #expect(conversation.messages.count == 1)
        #expect(message.text == "AI response")
        #expect(message.derivedState.streamState?.state == .completed)
        #expect(store.activeMessageStreamTargets().isEmpty)

        store.applyStreamSignal(
            .init(
                stream: IMTCPMessageStreamPayload(
                    streamID: streamID,
                    messageID: messageID.uuidString,
                    conversationID: conversationID.uuidString,
                    chunkIndex: 3,
                    deltaText: " late",
                    partialTextLength: 16,
                    state: .streaming,
                    serverTimestamp: Date(timeIntervalSince1970: 1_700_300_005)
                )
            ),
            currentUserID: Self.currentUserID
        )
        message = try #require(store.selectedConversation?.messages.first)
        #expect(message.text == "AI response")
        #expect(message.derivedState.streamState?.state == .completed)
    }

    @Test func asyncMessageStreamSignalUsesClientStateEngineAndProjectsMainActorState() async throws {
        let store = IMConversationStore()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let messageID = UUID(uuidString: "cccccccc-1111-2222-3333-dddddddddddd")!
        let streamID = "stream-async"
        let createdAt = Date(timeIntervalSince1970: 1_700_300_000)

        store.replaceConversationSummaries(
            [
                IMConversationSummaryResponseBody(
                    id: conversationID,
                    title: "AI Conversation",
                    memberUserIDs: [Self.currentUserID, Self.peerUserID],
                    lastMessage: nil,
                    createdAt: Date(timeIntervalSince1970: 1_700_200_000),
                    updatedAt: createdAt
                )
            ]
        )
        store.openConversation(id: conversationID.uuidString)

        let initialMessage = IMConversationMessageResponseBody(
            id: messageID,
            conversationID: conversationID,
            senderUserID: Self.currentUserID,
            serverSequence: 2,
            timelineSequence: 2,
            content: .richText(.plain("")),
            derivedState: IMMessageDerivedState(
                streamState: MessageStreamState(
                    streamID: streamID,
                    state: .streaming,
                    updatedAt: createdAt
                )
            ),
            createdAt: createdAt
        )
        await store.applyStreamSignalAsync(
            .init(
                stream: IMTCPMessageStreamPayload(
                    streamID: streamID,
                    messageID: messageID.uuidString,
                    conversationID: conversationID.uuidString,
                    chunkIndex: 0,
                    partialTextLength: 0,
                    state: .streaming,
                    serverTimestamp: createdAt
                ),
                message: initialMessage
            ),
            currentUserID: Self.currentUserID
        )

        await store.applyStreamSignalAsync(
            .init(
                stream: IMTCPMessageStreamPayload(
                    streamID: streamID,
                    messageID: messageID.uuidString,
                    conversationID: conversationID.uuidString,
                    chunkIndex: 1,
                    deltaText: "AI",
                    partialTextLength: 2,
                    state: .streaming,
                    serverTimestamp: Date(timeIntervalSince1970: 1_700_300_001)
                )
            ),
            currentUserID: Self.currentUserID
        )

        #expect(store.selectedConversation?.messages.first?.text == "AI")
        #expect(await store.activeMessageStreamTargetsAsync() == [
            IMActiveMessageStreamTarget(
                conversationID: conversationID.uuidString,
                messageID: messageID.uuidString,
                streamID: streamID
            )
        ])

        await store.applyStreamSignalAsync(
            .init(
                stream: IMTCPMessageStreamPayload(
                    streamID: streamID,
                    messageID: messageID.uuidString,
                    conversationID: conversationID.uuidString,
                    chunkIndex: 3,
                    deltaText: " gap",
                    partialTextLength: 6,
                    state: .streaming,
                    serverTimestamp: Date(timeIntervalSince1970: 1_700_300_003)
                )
            ),
            currentUserID: Self.currentUserID
        )

        let pendingTarget = IMActiveMessageStreamTarget(
            conversationID: conversationID.uuidString,
            messageID: messageID.uuidString,
            streamID: streamID
        )
        #expect(await store.consumePendingStreamSnapshotTargetsAsync() == [pendingTarget])
        let remainingPendingTargets = await store.consumePendingStreamSnapshotTargetsAsync()
        #expect(remainingPendingTargets.isEmpty)

        let completedAt = Date(timeIntervalSince1970: 1_700_300_004)
        await store.applyMessageStreamSnapshotAsync(
            IMMessageStreamResponseBody(
                message: IMConversationMessageResponseBody(
                    id: messageID,
                    conversationID: conversationID,
                    senderUserID: Self.currentUserID,
                    serverSequence: 2,
                    timelineSequence: 2,
                    content: .richText(.plain("AI response")),
                    derivedState: IMMessageDerivedState(
                        streamState: MessageStreamState(
                            streamID: streamID,
                            state: .completed,
                            lastChunkIndex: Int.max,
                            partialText: "AI response",
                            updatedAt: completedAt
                        )
                    ),
                    createdAt: completedAt
                ),
                stream: IMTCPMessageStreamPayload(
                    streamID: streamID,
                    messageID: messageID.uuidString,
                    conversationID: conversationID.uuidString,
                    chunkIndex: Int.max,
                    partialTextLength: 11,
                    state: .completed,
                    serverTimestamp: completedAt
                )
            ),
            currentUserID: Self.currentUserID
        )

        let message = try #require(store.selectedConversation?.messages.first)
        #expect(message.text == "AI response")
        #expect(message.derivedState.streamState?.state == .completed)
        let activeTargets = await store.activeMessageStreamTargetsAsync()
        #expect(activeTargets.isEmpty)
    }


    @Test func messageUpdatedEventStoresReactionDerivedState() {
        let store = IMConversationStore()
        let conversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let messageID = UUID(uuidString: "cccccccc-1111-2222-3333-dddddddddddd")!
        let createdAt = Date(timeIntervalSince1970: 1_700_300_000)
        let reactionState = IMMessageDerivedState(
            reactions: [
                .init(emoji: "👍", actorUserIDs: [Self.currentUserID]),
                .init(emoji: "❤️", actorUserIDs: [Self.peerUserID])
            ]
        )

        store.replaceConversationSummaries(
            [
                IMConversationSummaryResponseBody(
                    id: conversationID,
                    title: "Server Conversation",
                    memberUserIDs: [Self.currentUserID, Self.peerUserID],
                    lastMessage: nil,
                    createdAt: Date(timeIntervalSince1970: 1_700_200_000),
                    updatedAt: createdAt
                )
            ]
        )

        store.applyUpdatedMessage(
            IMConversationMessageResponseBody(
                id: messageID,
                conversationID: conversationID,
                senderUserID: Self.peerUserID,
                clientMessageID: nil,
                serverSequence: 2,
                timelineSequence: 2,
                content: .richText(.plain("react here")),
                derivedState: reactionState,
                createdAt: createdAt
            ),
            currentUserID: Self.currentUserID
        )

        let message = store.selectedConversation?.messages.last
        #expect(message?.derivedState.reactions == reactionState.reactions)
    }


    @Test func conversationRemovedForSelfEventRemovesConversationAndFallsBackSelection() {
        let store = IMConversationStore()
        let removedConversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let restoredConversationID = UUID(uuidString: "bbbbbbbb-1111-2222-3333-cccccccccccc")!

        store.replaceConversationSummaries(
            [
                IMConversationSummaryResponseBody(
                    id: removedConversationID,
                    title: "Current",
                    memberUserIDs: [Self.currentUserID, Self.peerUserID],
                    lastMessage: nil,
                    createdAt: Date(timeIntervalSince1970: 1_700_200_001),
                    updatedAt: Date(timeIntervalSince1970: 1_700_300_001)
                ),
                IMConversationSummaryResponseBody(
                    id: restoredConversationID,
                    title: "Fallback",
                    memberUserIDs: [Self.currentUserID, Self.peerUserID],
                    lastMessage: nil,
                    createdAt: Date(timeIntervalSince1970: 1_700_200_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_300_000)
                )
            ]
        )
        store.openConversation(id: removedConversationID.uuidString)

        _ = store.applyTestConversationEvent(
            TestConversationEventPayload(
                eventType: .conversationRemovedForSelf,
                conversation: IMConversationSummaryResponseBody(
                    id: removedConversationID,
                    title: "Current",
                    memberUserIDs: [Self.currentUserID, Self.peerUserID],
                    lastMessage: nil,
                    createdAt: Date(timeIntervalSince1970: 1_700_200_001),
                    updatedAt: Date(timeIntervalSince1970: 1_700_300_001)
                ),
                actorUserID: Self.currentUserID,
                serverTimestamp: Date(timeIntervalSince1970: 1_700_300_100)
            ),
            currentUserID: Self.currentUserID
        )

        #expect(store.conversations.count == 1)
        #expect(store.conversations.first?.id == restoredConversationID.uuidString)
        #expect(store.selectedConversationID == restoredConversationID.uuidString)
    }


    @Test func openConversationOnlyChangesSelection() {
        let store = IMConversationStore()
        let selectedConversationID = UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!
        let unreadConversationID = UUID(uuidString: "bbbbbbbb-1111-2222-3333-cccccccccccc")!

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
                    id: unreadConversationID,
                    title: "unread",
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
                conversationID: unreadConversationID.uuidString,
                senderUserID: Self.peerUserID,
                serverSequence: 1,
                serverTimestamp: Date(timeIntervalSince1970: 1_700_300_000),
                kind: "rich_text",
                body: ["text": "unread"]
            ),
            currentUserID: Self.currentUserID
        )

        #expect(store.totalUnreadCount == 1)

        store.openConversation(id: unreadConversationID.uuidString)

        #expect(store.selectedConversationID == unreadConversationID.uuidString)
        #expect(store.selectedConversation?.unreadCount == 1)
        #expect(store.totalUnreadCount == 1)

        store.markConversationRead(id: unreadConversationID.uuidString)

        #expect(store.selectedConversation?.unreadCount == 0)
        #expect(store.totalUnreadCount == 0)
    }


    @Test func applyRealtimeUnreadIncrementOnlyAffectsBackgroundConversation() {
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

        store.applyRealtimeUnreadIncrement(for: backgroundConversationID.uuidString)

        let backgroundConversation = store.conversations.first { $0.id == backgroundConversationID.uuidString }
        #expect(backgroundConversation?.unreadCount == 1)
        #expect(store.totalUnreadCount == 1)

        store.applyRealtimeUnreadIncrement(for: selectedConversationID.uuidString)

        let selectedConversation = store.conversations.first { $0.id == selectedConversationID.uuidString }
        #expect(selectedConversation?.unreadCount == 0)
        #expect(store.totalUnreadCount == 1)
    }


    @Test func applyServerUnreadCountMergesWithLocalRealtimeUnreadDelta() {
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

        store.applyServerUnreadCount(2, for: backgroundConversationID.uuidString)
        store.applyRealtimeUnreadIncrement(for: backgroundConversationID.uuidString)

        let backgroundConversation = store.conversations.first { $0.id == backgroundConversationID.uuidString }
        #expect(backgroundConversation?.serverUnreadCount == 2)
        #expect(backgroundConversation?.localUnreadDelta == 1)
        #expect(backgroundConversation?.unreadCount == 3)
        #expect(store.totalUnreadCount == 3)
    }


    @Test func applyServerSummaryReadStatesKeepsLocalRealtimeUnreadDelta() {
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

        store.applyRealtimeUnreadIncrement(for: backgroundConversationID.uuidString)
        store.applyServerSummaryReadStates(
            [
                IMConversationSummaryResponseBody(
                    id: backgroundConversationID,
                    title: "background",
                    memberUserIDs: [Self.currentUserID, Self.peerUserID],
                    lastMessage: nil,
                    lastReadSequence: 8,
                    unreadCount: 2,
                    createdAt: Date(timeIntervalSince1970: 1_700_200_001),
                    updatedAt: Date(timeIntervalSince1970: 1_700_200_010)
                )
            ]
        )

        let backgroundConversation = store.conversations.first { $0.id == backgroundConversationID.uuidString }
        #expect(backgroundConversation?.serverLastReadSequence == 8)
        #expect(backgroundConversation?.serverUnreadCount == 2)
        #expect(backgroundConversation?.localUnreadDelta == 1)
        #expect(backgroundConversation?.unreadCount == 3)
    }


    @Test func applyServerSummaryReadStateClearsLocalRealtimeUnreadDeltaOnceServerSummaryCatchesUp() {
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
                    lastReadSequence: 5,
                    unreadCount: 2,
                    createdAt: Date(timeIntervalSince1970: 1_700_200_001),
                    updatedAt: Date(timeIntervalSince1970: 1_700_200_001)
                )
            ]
        )
        store.replaceTimelineItems(
            in: backgroundConversationID.uuidString,
            messages: [
                IMConversationMessageResponseBody(
                    id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                    conversationID: backgroundConversationID,
                    senderUserID: Self.peerUserID,
                    clientMessageID: nil,
                    serverSequence: 6,
                    timelineSequence: 6,
                    content: .richText(.plain("six")),
                    createdAt: Date(timeIntervalSince1970: 1_700_200_006)
                ),
                IMConversationMessageResponseBody(
                    id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                    conversationID: backgroundConversationID,
                    senderUserID: Self.peerUserID,
                    clientMessageID: nil,
                    serverSequence: 8,
                    timelineSequence: 8,
                    content: .richText(.plain("eight")),
                    createdAt: Date(timeIntervalSince1970: 1_700_200_008)
                )
            ],
            currentUserID: Self.currentUserID
        )

        store.applyTestDomainMessage(
            IMTCPMessagePayload(
                clientMessageID: nil,
                messageID: "srv-live-9",
                conversationID: backgroundConversationID.uuidString,
                senderUserID: Self.peerUserID,
                serverSequence: 9,
                serverTimestamp: Date(timeIntervalSince1970: 1_700_200_009),
                content: .richText(.plain("live"))
            ),
            currentUserID: Self.currentUserID
        )

        store.applyServerSummaryReadState(
            lastReadSequence: 5,
            unreadCount: 3,
            for: backgroundConversationID.uuidString
        )

        let backgroundConversation = store.conversations.first { $0.id == backgroundConversationID.uuidString }
        #expect(backgroundConversation?.serverUnreadCount == 3)
        #expect(backgroundConversation?.localUnreadDelta == 0)
        #expect(backgroundConversation?.unreadCount == 3)
    }


    @Test func applyServerSummaryReadStateClearsLocalRealtimeUnreadDeltaWhenAnotherDeviceAdvancesReadSequence() {
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
                    lastReadSequence: 5,
                    unreadCount: 2,
                    createdAt: Date(timeIntervalSince1970: 1_700_200_001),
                    updatedAt: Date(timeIntervalSince1970: 1_700_200_001)
                )
            ]
        )
        store.replaceTimelineItems(
            in: backgroundConversationID.uuidString,
            messages: [
                IMConversationMessageResponseBody(
                    id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
                    conversationID: backgroundConversationID,
                    senderUserID: Self.peerUserID,
                    clientMessageID: nil,
                    serverSequence: 8,
                    timelineSequence: 8,
                    content: .richText(.plain("eight")),
                    createdAt: Date(timeIntervalSince1970: 1_700_200_008)
                )
            ],
            currentUserID: Self.currentUserID
        )

        store.applyTestDomainMessage(
            IMTCPMessagePayload(
                clientMessageID: nil,
                messageID: "srv-live-9",
                conversationID: backgroundConversationID.uuidString,
                senderUserID: Self.peerUserID,
                serverSequence: 9,
                serverTimestamp: Date(timeIntervalSince1970: 1_700_200_009),
                content: .richText(.plain("live"))
            ),
            currentUserID: Self.currentUserID
        )

        store.applyServerSummaryReadState(
            lastReadSequence: 9,
            unreadCount: 0,
            for: backgroundConversationID.uuidString
        )

        let backgroundConversation = store.conversations.first { $0.id == backgroundConversationID.uuidString }
        #expect(backgroundConversation?.serverLastReadSequence == 9)
        #expect(backgroundConversation?.serverUnreadCount == 0)
        #expect(backgroundConversation?.localUnreadDelta == 0)
        #expect(backgroundConversation?.unreadCount == 0)
    }


    @Test func applyServerExplicitReadResponseResetsLocalRealtimeUnreadDelta() {
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

        store.applyRealtimeUnreadIncrement(for: backgroundConversationID.uuidString)
        store.applyServerExplicitReadResponse(
            IMConversationReadResponseBody(
                conversationID: backgroundConversationID,
                lastReadSequence: 9,
                unreadCount: 0
            )
        )

        let backgroundConversation = store.conversations.first { $0.id == backgroundConversationID.uuidString }
        #expect(backgroundConversation?.serverLastReadSequence == 9)
        #expect(backgroundConversation?.serverUnreadCount == 0)
        #expect(backgroundConversation?.localUnreadDelta == 0)
        #expect(backgroundConversation?.unreadCount == 0)
    }

    @Test func asyncReadStateUsesClientStateEngineAndProjectsMainActorState() async {
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

        await store.applyRealtimeUnreadIncrementAsync(for: backgroundConversationID.uuidString)
        #expect(store.conversations.first { $0.id == backgroundConversationID.uuidString }?.unreadCount == 1)

        await store.applyServerExplicitReadResponseAsync(
            IMConversationReadResponseBody(
                conversationID: backgroundConversationID,
                lastReadSequence: 9,
                unreadCount: 0
            )
        )
        #expect(store.conversations.first { $0.id == backgroundConversationID.uuidString }?.unreadCount == 0)

        await store.markConversationUnreadAsync(id: backgroundConversationID.uuidString)
        #expect(store.conversations.first { $0.id == backgroundConversationID.uuidString }?.localUnreadDelta == 1)

        await store.markConversationReadAsync(id: backgroundConversationID.uuidString)
        #expect(store.conversations.first { $0.id == backgroundConversationID.uuidString }?.unreadCount == 0)
    }


}
