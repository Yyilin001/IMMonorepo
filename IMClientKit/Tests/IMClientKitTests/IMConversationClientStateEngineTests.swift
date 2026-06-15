import Foundation
import Testing
@testable import IMClientKit

struct IMConversationClientStateEngineTests {
    @Test func engineReducesSummaryStateIntoActorSnapshot() async {
        let firstID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        let secondID = UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
        let engine = IMConversationClientStateEngine(
            state: IMConversationClientState(
                statusMessage: "loading",
                isLoadingMoreConversationSummaries: true
            )
        )

        let effect = await engine.reduceSummaryState(
            .replaceConversationSummaryWindow(
                [
                    Self.makeSummary(id: firstID, title: "First", updatedAt: 20),
                    Self.makeSummary(id: secondID, title: "Second", updatedAt: 10)
                ],
                nextCursor: "cursor-2",
                hasMore: true
            ),
            replacingSummaryContent: Self.makeConversation(from:existing:),
            summaryContent: Self.makeConversation(from:existing:),
            upsertSummaryContents: Self.upsertSummaries(_:conversations:),
            upsertSummaryContent: Self.upsertSummary(_:conversations:),
            ensureConversationIndex: Self.ensureConversationIndex(for:conversations:)
        )
        let snapshot = await engine.snapshot()

        #expect(effect.shouldSortConversations)
        #expect(snapshot.conversations.map(\.id) == [firstID.uuidString, secondID.uuidString])
        #expect(snapshot.selectedConversationID == firstID.uuidString)
        #expect(snapshot.conversationSummaryNextCursor == "cursor-2")
        #expect(snapshot.hasMoreConversationSummaries)
        #expect(!snapshot.isLoadingMoreConversationSummaries)
        #expect(snapshot.statusMessage == nil)
    }

    @Test func engineReducesMessageStateIntoActorSnapshot() async throws {
        let conversationID = "conversation-message"
        let clientMessageID = "client-message-id"
        let messageID = "server-message-id"
        let engine = IMConversationClientStateEngine(
            state: IMConversationClientState(
                conversations: [
                    Self.makeConversation(
                        id: conversationID,
                        pendingMessages: [
                            IMPendingConversationMessage(
                                localMessageID: clientMessageID,
                                clientMessageID: clientMessageID,
                                conversationID: conversationID,
                                senderUserID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                                content: .richText(.plain("pending")),
                                createdAt: Date(timeIntervalSince1970: 1),
                                deliveryState: .sending
                            )
                        ]
                    )
                ],
                statusMessage: "loading"
            )
        )
        let message = try Self.makeMessage(
            id: messageID,
            conversationID: conversationID,
            clientMessageID: clientMessageID,
            senderUserID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            sequence: 2,
            text: "canonical",
            direction: .outgoing,
            deliveryState: .sent
        )

        let effect = await engine.reduceMessageState(
            .applyCreatedMessage(message, clientMessageID: clientMessageID),
            ensureConversationIndex: Self.ensureConversationIndex(for:conversations:),
            latestMessagePreviewText: Self.latestPreviewText(in:fallback:),
            latestMessageUpdatedAt: Self.latestUpdatedAt(in:fallback:),
            messageComparator: Self.messageComparator(_:_:)
        )
        let snapshot = await engine.snapshot()

        #expect(effect.didMutate)
        #expect(effect.shouldSortConversations)
        #expect(snapshot.statusMessage == nil)
        #expect(snapshot.selectedConversationID == conversationID)
        #expect(snapshot.conversations.first?.pendingMessages.isEmpty == true)
        #expect(snapshot.conversations.first?.messages.map(\.clientMessageID) == [clientMessageID])
    }

    @Test func engineReducesOutgoingStateIntoActorSnapshot() async {
        let conversationID = "conversation-outgoing"
        let requestID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let clientMessageID = "local-client-message-id"
        let engine = IMConversationClientStateEngine(
            state: IMConversationClientState(
                conversations: [
                    Self.makeConversation(id: conversationID)
                ],
                statusMessage: "loading"
            )
        )

        let effect = await engine.reduceOutgoingState(
            .appendOutgoingMessage(
                content: .richText(.plain("queued text")),
                conversationID: conversationID,
                senderUserID: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
                deliveryState: .queued(message: "queued"),
                shouldRegisterPendingRequest: false,
                localTransferState: nil,
                requestID: requestID,
                clientMessageID: clientMessageID,
                createdAt: Date(timeIntervalSince1970: 10)
            ),
            ensureConversationIndex: Self.ensureConversationIndex(for:conversations:),
            latestMessagePreviewText: Self.latestPreviewText(in:fallback:),
            latestMessageUpdatedAt: Self.latestUpdatedAt(in:fallback:),
            isRetryableFailure: Self.isRetryableFailure(_:)
        )
        let snapshot = await engine.snapshot()

        #expect(effect.didApply)
        #expect(effect.shouldSortConversations)
        #expect(effect.placeholder?.localMessageID == clientMessageID)
        #expect(snapshot.selectedConversationID == conversationID)
        #expect(snapshot.statusMessage == nil)
        #expect(snapshot.conversations.first?.pendingMessages.map(\.clientMessageID) == [clientMessageID])
        #expect(snapshot.conversations.first?.lastMessagePreviewText == "queued text")
    }

    @Test func engineReducesLoadingStateIntoActorSnapshot() async {
        let engine = IMConversationClientStateEngine()

        await engine.reduceLoadingState(.setLoadingConversations(true))
        await engine.reduceLoadingState(.setLoadingMoreConversationSummaries(true))
        await engine.reduceLoadingState(.setLoadingMembers(true))
        await engine.reduceLoadingState(.setLoadingMessages(true))
        let loadingSnapshot = await engine.snapshot()

        #expect(loadingSnapshot.isLoadingConversations)
        #expect(loadingSnapshot.isLoadingMoreConversationSummaries)
        #expect(loadingSnapshot.detailState.isLoadingMembers)
        #expect(loadingSnapshot.detailState.isLoadingMessages)

        await engine.reduceLoadingState(.setLoadingConversations(false))
        await engine.reduceLoadingState(.setLoadingMoreConversationSummaries(false))
        await engine.reduceLoadingState(.setLoadingMembers(false))
        await engine.reduceLoadingState(.setLoadingMessages(false))
        let idleSnapshot = await engine.snapshot()

        #expect(!idleSnapshot.isLoadingConversations)
        #expect(!idleSnapshot.isLoadingMoreConversationSummaries)
        #expect(!idleSnapshot.detailState.isLoadingMembers)
        #expect(!idleSnapshot.detailState.isLoadingMessages)
    }

    @Test func engineReducesTimelineNoticeIntoActorSnapshot() async throws {
        let conversationID = "conversation-timeline"
        let noticeID = "notice-1"
        let engine = IMConversationClientStateEngine(
            state: IMConversationClientState(
                conversations: [
                    Self.makeConversation(id: conversationID)
                ],
                statusMessage: "loaded"
            )
        )
        let originalNotice = try Self.makeNotice(
            id: noticeID,
            conversationID: conversationID,
            timelineSequence: 2,
            fallbackText: "original"
        )
        let replacementNotice = try Self.makeNotice(
            id: noticeID,
            conversationID: conversationID,
            timelineSequence: 1,
            fallbackText: "replacement"
        )

        await engine.reduceTimelineState(
            .upsertNotice(originalNotice),
            ensureConversationIndex: Self.ensureConversationIndex(for:conversations:),
            makeMessages: Self.makeMessages(from:currentUserID:),
            makeNotices: Self.makeNotices(from:),
            mergeMessages: Self.mergeMessages(existing:serverMessages:preserveExistingServerMessages:),
            hasOlderHistory: Self.hasOlderHistory(in:)
        )
        await engine.reduceTimelineState(
            .upsertNotice(replacementNotice),
            ensureConversationIndex: Self.ensureConversationIndex(for:conversations:),
            makeMessages: Self.makeMessages(from:currentUserID:),
            makeNotices: Self.makeNotices(from:),
            mergeMessages: Self.mergeMessages(existing:serverMessages:preserveExistingServerMessages:),
            hasOlderHistory: Self.hasOlderHistory(in:)
        )
        let snapshot = await engine.snapshot()

        #expect(snapshot.statusMessage == "loaded")
        #expect(snapshot.conversations.first?.notices.count == 1)
        #expect(snapshot.conversations.first?.notices.first?.id == noticeID)
        #expect(snapshot.conversations.first?.notices.first?.timelineSequence == 1)
        #expect(snapshot.conversations.first?.notices.first?.fallbackText == "replacement")
    }

    @Test func engineSnapshotsDomainEventReducerState() async {
        let engine = IMConversationClientStateEngine()
        let eventID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

        let consumedSnapshot = await engine.reduceDomainEventState(
            .recordConsumedEvent(
                eventID: eventID,
                aggregateType: "conversation",
                aggregateID: "conversation-1",
                ownerAggregateSequence: 3
            )
        )
        let advancedSnapshot = await engine.reduceDomainEventState(.advanceCursor(42))

        let highWatermarkKey = IMOwnerAggregateKey(
            aggregateType: "conversation",
            aggregateID: "conversation-1"
        )
        #expect(consumedSnapshot.domainEventState.processedEventIDs == [eventID])
        #expect(consumedSnapshot.domainEventState.processedEventIDOrder == [eventID])
        #expect(consumedSnapshot.domainEventState.ownerAggregateHighWatermarks[highWatermarkKey] == 3)
        #expect(advancedSnapshot.domainEventCursor == 42)
        #expect(advancedSnapshot.healthSnapshot.domainEventCursor == 42)
    }

    @Test func engineBuildsDependencySnapshotFromCurrentState() async throws {
        let eventID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let highWatermarkKey = IMOwnerAggregateKey(
            aggregateType: "conversation",
            aggregateID: "conversation-1"
        )
        let message = try makeMessage(
            id: "local-message-1",
            serverMessageID: "server-message-1",
            conversationID: "conversation-1"
        )
        let engine = IMConversationClientStateEngine(
            state: IMConversationClientState(
                conversations: [
                    conversation(
                        id: "conversation-1",
                        messages: [message]
                    )
                ],
                domainEventState: IMConversationDomainEventState(
                    processedEventIDs: [eventID],
                    processedEventIDOrder: [eventID],
                    ownerAggregateHighWatermarks: [highWatermarkKey: 7],
                    cursor: 1
                )
            )
        )

        let snapshot = await engine.dependencySnapshot()

        #expect(snapshot.processedEventIDs == [eventID])
        #expect(snapshot.ownerAggregateHighWatermarks[highWatermarkKey] == 7)
        #expect(snapshot.existingMessageKeys == [
            DomainEventProjectionReducer.MessageKey(
                conversationID: "conversation-1",
                messageID: "local-message-1"
            ),
            DomainEventProjectionReducer.MessageKey(
                conversationID: "conversation-1",
                messageID: "server-message-1"
            )
        ])
    }

    @Test func engineClearsFullRefreshConversationAndMatchingDeferredEvents() async {
        let engine = IMConversationClientStateEngine()
        let conversationKey = IMDeferredDomainEventMissingKey.conversation("conversation-1")
        let messageKey = IMDeferredDomainEventMissingKey.message("message-2")

        let firstStoreResult = await engine.storeDeferredEvent(
            deferredEvent(
                eventID: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
                conversationID: "conversation-1",
                missingKey: conversationKey,
                firstSeenAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
        )
        let secondStoreResult = await engine.storeDeferredEvent(
            deferredEvent(
                eventID: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
                conversationID: "conversation-2",
                missingKey: messageKey,
                firstSeenAt: Date(timeIntervalSince1970: 1_700_000_001)
            )
        )
        let didMark = await engine.markFullRefreshConversation(" conversation-1 ")
        let didClear = await engine.clearFullRefreshConversation("conversation-1")
        let snapshot = await engine.snapshot()

        #expect(firstStoreResult == .stored)
        #expect(secondStoreResult == .stored)
        #expect(didMark)
        #expect(didClear)
        #expect(snapshot.deferredDomainEventState.fullRefreshConversationIDs.isEmpty)
        #expect(snapshot.deferredDomainEventState.eventsByMissingKey[conversationKey] == nil)
        #expect(snapshot.deferredDomainEventState.eventsByMissingKey[messageKey]?.count == 1)
        #expect(snapshot.healthSnapshot.deferredDomainEventCount == 1)
    }

    @Test func engineMarksExistingConversationAsNeedingFullRefreshWhenDeferredLimitOverflows() async {
        let engine = IMConversationClientStateEngine(
            state: IMConversationClientState(
                conversations: [
                    Self.makeConversation(id: "conversation-1")
                ]
            )
        )
        let missingKey = IMDeferredDomainEventMissingKey.conversation("conversation-1")
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        for offset in 0..<201 {
            _ = await engine.storeDeferredEvent(
                deferredEvent(
                    eventID: UUID(uuidString: String(format: "aaaaaaaa-aaaa-aaaa-aaaa-%012d", offset))!,
                    conversationID: "conversation-1",
                    missingKey: missingKey,
                    firstSeenAt: now.addingTimeInterval(Double(offset))
                )
            )
        }
        let effect = await engine.enforceDeferredEventLimits(
            conversationID: "conversation-1",
            now: now
        )

        let snapshot = await engine.snapshot()

        #expect(effect.fullRefreshConversationID == "conversation-1")
        #expect(snapshot.conversations.first?.hasMoreHistory == true)
        #expect(snapshot.deferredDomainEventState.fullRefreshConversationIDs == ["conversation-1"])
        #expect(snapshot.domainEventDebugMetrics.deferredFullRefreshRequested == 1)
    }

    @Test func snapshotStreamYieldsCurrentSnapshotAndCommittedUpdates() async {
        let engine = IMConversationClientStateEngine()
        let stream = await engine.snapshots()
        var iterator = stream.makeAsyncIterator()

        let initialSnapshot = await iterator.next()
        await engine.reduceDomainEventState(.advanceCursor(5))
        let updatedSnapshot = await iterator.next()

        #expect(initialSnapshot?.domainEventCursor == 0)
        #expect(updatedSnapshot?.domainEventCursor == 5)
    }

    @Test func snapshotStreamBuffersOnlyNewestSnapshotWhenConsumerLags() async {
        let engine = IMConversationClientStateEngine()
        let stream = await engine.snapshots()

        await engine.reduceDomainEventState(.advanceCursor(1))
        await engine.reduceDomainEventState(.advanceCursor(2))

        var iterator = stream.makeAsyncIterator()
        let snapshot = await iterator.next()

        #expect(snapshot?.domainEventCursor == 2)
    }

    private func deferredEvent(
        eventID: UUID,
        conversationID: String?,
        missingKey: IMDeferredDomainEventMissingKey,
        firstSeenAt: Date,
        retryCount: Int = 0,
        ownerCursor: UInt64? = nil,
        ownerAggregateSequence: UInt64? = nil,
        eventPBBase64: String = "payload"
    ) -> IMDeferredDomainEventState {
        IMDeferredDomainEventState(
            eventID: eventID,
            conversationID: conversationID,
            missingKey: missingKey,
            firstSeenAt: firstSeenAt,
            retryCount: retryCount,
            ownerCursor: ownerCursor,
            ownerAggregateSequence: ownerAggregateSequence,
            eventPBBase64: eventPBBase64
        )
    }

    private func conversation(
        id: String,
        messages: [IMConversationMessage] = []
    ) -> IMConversation {
        IMConversation(
            id: id,
            title: "Conversation",
            kind: .direct,
            memberCount: 1,
            memberUserIDs: [
                UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
            ],
            members: [],
            messages: messages,
            lastMessagePreviewText: messages.last?.text ?? "",
            hasMoreHistory: false,
            serverLastReadSequence: 0,
            serverUnreadCount: 0,
            localUnreadDelta: 0,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func makeMessage(
        id: String,
        serverMessageID: String,
        conversationID: String
    ) throws -> IMConversationMessage {
        try IMConversationMessage(
            id: id,
            conversationID: conversationID,
            clientMessageID: nil,
            serverMessageID: serverMessageID,
            senderUserID: UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!,
            serverSequence: 1,
            timelineSequence: 1,
            content: .richText(.plain("message")),
            direction: .incoming,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            deliveryState: .received
        )
    }

    private static func makeSummary(
        id: UUID,
        title: String,
        updatedAt: TimeInterval
    ) -> IMConversationSummaryResponseBody {
        IMConversationSummaryResponseBody(
            id: id,
            title: title,
            kind: IMConversationKind.group.rawValue,
            memberCount: 2,
            memberUserIDs: [
                UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
                UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
            ],
            lastMessage: nil,
            createdAt: Date(timeIntervalSince1970: updatedAt - 1),
            updatedAt: Date(timeIntervalSince1970: updatedAt)
        )
    }

    private static func makeConversation(
        from response: IMConversationSummaryResponseBody,
        existing: IMConversation?
    ) -> IMConversation {
        IMConversation(
            id: response.id.uuidString,
            title: response.title ?? existing?.title ?? response.id.uuidString,
            kind: IMConversationKind(rawValue: response.kind) ?? .group,
            directMessagingState: nil,
            directPeer: nil,
            notice: response.notice,
            avatarPreset: response.avatarPreset,
            muteAll: response.muteAll,
            memberCount: response.memberCount,
            memberUserIDs: response.memberUserIDs,
            members: existing?.members ?? [],
            messages: existing?.messages ?? [],
            lastMessagePreviewText: existing?.lastMessagePreviewText ?? "",
            hasMoreHistory: existing?.hasMoreHistory ?? false,
            serverLastReadSequence: response.lastReadSequence,
            serverUnreadCount: response.unreadCount,
            localUnreadDelta: existing?.localUnreadDelta ?? 0,
            isPinned: response.isPinned,
            pinnedAt: response.pinnedAt,
            isMuted: response.isMuted,
            draftText: existing?.draftText ?? "",
            draftUpdatedAt: existing?.draftUpdatedAt,
            updatedAt: response.updatedAt
        )
    }

    private static func makeConversation(
        id: String,
        messages: [IMConversationMessage] = [],
        pendingMessages: [IMPendingConversationMessage] = []
    ) -> IMConversation {
        IMConversation(
            id: id,
            title: "Actor State",
            kind: .group,
            memberCount: 2,
            memberUserIDs: [],
            members: [],
            messages: messages,
            pendingMessages: pendingMessages,
            lastMessagePreviewText: messages.last?.text ?? pendingMessages.last?.text ?? "old preview",
            hasMoreHistory: false,
            serverLastReadSequence: 0,
            serverUnreadCount: 0,
            localUnreadDelta: 0,
            draftText: "draft",
            draftUpdatedAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1)
        )
    }

    private static func ensureConversationIndex(
        for conversationID: String,
        conversations: inout [IMConversation]
    ) -> Int {
        if let index = conversations.firstIndex(where: { $0.id == conversationID }) {
            return index
        }
        conversations.append(makeConversation(id: conversationID))
        return conversations.count - 1
    }

    private static func makeMessage(
        id: String,
        conversationID: String,
        clientMessageID: String? = nil,
        senderUserID: UUID,
        sequence: UInt64,
        text: String,
        direction: IMMessageDirection,
        deliveryState: IMMessageDeliveryState
    ) throws -> IMConversationMessage {
        try IMConversationMessage(
            id: id,
            conversationID: conversationID,
            clientMessageID: clientMessageID,
            serverMessageID: id,
            senderUserID: senderUserID,
            serverSequence: sequence,
            timelineSequence: sequence,
            content: .richText(.plain(text)),
            direction: direction,
            createdAt: Date(timeIntervalSince1970: Double(sequence)),
            deliveryState: deliveryState
        )
    }

    private static func makeNotice(
        id: String,
        conversationID: String,
        timelineSequence: UInt64,
        fallbackText: String
    ) throws -> IMTimelineNotice {
        try IMTimelineNotice(
            id: id,
            conversationID: conversationID,
            timelineSequence: timelineSequence,
            eventType: "test.notice",
            actorUserID: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!,
            targetUserIDs: [],
            noticeKind: "test",
            params: [:],
            fallbackText: fallbackText,
            createdAt: Date(timeIntervalSince1970: Double(timelineSequence))
        )
    }

    private static func makeMessages(
        from responses: [IMConversationMessageResponseBody],
        currentUserID: UUID
    ) -> [IMConversationMessage] {
        responses.compactMap { response in
            try? IMConversationMessage(
                id: response.id.uuidString,
                conversationID: response.conversationID.uuidString,
                clientMessageID: response.clientMessageID,
                serverMessageID: response.id.uuidString,
                senderUserID: response.senderUserID,
                serverSequence: UInt64(response.serverSequence),
                timelineSequence: UInt64(response.timelineSequence),
                content: response.content,
                derivedState: response.derivedState,
                direction: response.senderUserID == currentUserID ? .outgoing : .incoming,
                createdAt: response.createdAt ?? .distantPast,
                deliveryState: response.senderUserID == currentUserID ? .sent : .received
            )
        }
    }

    private static func makeNotices(from responses: [IMTimelineNoticeResponseBody]) -> [IMTimelineNotice] {
        responses.compactMap { response in
            try? IMTimelineNotice(
                id: response.id.uuidString,
                conversationID: response.conversationID.uuidString,
                timelineSequence: UInt64(response.timelineSequence),
                eventType: response.eventType,
                actorUserID: response.actorUserID,
                targetUserIDs: response.targetUserIDs,
                noticeKind: response.noticeKind,
                params: response.params,
                fallbackText: response.fallbackText,
                createdAt: response.createdAt
            )
        }
    }

    private static func mergeMessages(
        existing: [IMConversationMessage],
        serverMessages: [IMConversationMessage],
        preserveExistingServerMessages: Bool
    ) -> [IMConversationMessage] {
        var merged = preserveExistingServerMessages ? existing : []
        for serverMessage in serverMessages {
            if let existingIndex = merged.firstIndex(where: { $0.id == serverMessage.id || $0.serverMessageID == serverMessage.serverMessageID }) {
                merged[existingIndex] = serverMessage
            } else {
                merged.append(serverMessage)
            }
        }
        return merged.sorted(by: messageComparator(_:_:))
    }

    private static func hasOlderHistory(in serverMessages: [IMConversationMessage]) -> Bool {
        guard let oldestSequence = serverMessages.map(\.serverSequence).min() else {
            return false
        }
        return oldestSequence > 1
    }

    private static func upsertSummaries(
        _ responses: [IMConversationSummaryResponseBody],
        conversations: inout [IMConversation]
    ) {
        for response in responses {
            upsertSummary(response, conversations: &conversations)
        }
    }

    private static func upsertSummary(
        _ response: IMConversationSummaryResponseBody,
        conversations: inout [IMConversation]
    ) {
        let conversation = makeConversation(
            from: response,
            existing: conversations.first { $0.id == response.id.uuidString }
        )
        if let index = conversations.firstIndex(where: { $0.id == response.id.uuidString }) {
            conversations[index] = conversation
        } else {
            conversations.append(conversation)
        }
    }

    private static func latestPreviewText(
        in messages: [IMConversationMessage],
        fallback: String
    ) -> String {
        messages.last?.text ?? fallback
    }

    private static func latestUpdatedAt(
        in messages: [IMConversationMessage],
        fallback: Date
    ) -> Date {
        messages.last?.createdAt ?? fallback
    }

    private static func messageComparator(
        _ lhs: IMConversationMessage,
        _ rhs: IMConversationMessage
    ) -> Bool {
        if lhs.timelineSequence == rhs.timelineSequence {
            return lhs.id < rhs.id
        }
        return lhs.timelineSequence < rhs.timelineSequence
    }

    private static func isRetryableFailure(_ message: IMPendingConversationMessage) -> Bool {
        switch message.deliveryState {
        case .queued, .unknown, .failed:
            return true
        case .preparing, .uploading, .uploaded, .sending, .sent, .received:
            return false
        }
    }
}
