import Foundation
import Testing
@testable import IMClientKit

struct IMConversationDeferredDomainEventStateReducerTests {
    @Test func reducerStoresDuplicateDeferredEventByBumpingRetryAndPreservingFirstSeen() {
        let reducer = IMConversationDeferredDomainEventStateReducer()
        let eventID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let missingKey = IMDeferredDomainEventMissingKey.message("message-1")
        let firstSeenAt = Date(timeIntervalSince1970: 1_700_000_000)
        var state = IMConversationDeferredDomainEventState(
            eventsByMissingKey: [:],
            fullRefreshConversationIDs: []
        )

        let firstResult = reducer.store(
            deferredEvent(
                eventID: eventID,
                conversationID: "conversation-1",
                missingKey: missingKey,
                firstSeenAt: firstSeenAt,
                retryCount: 0,
                ownerCursor: 10,
                ownerAggregateSequence: 1,
                eventPBBase64: "first"
            ),
            state: &state
        )
        let duplicateResult = reducer.store(
            deferredEvent(
                eventID: eventID,
                conversationID: "conversation-2",
                missingKey: missingKey,
                firstSeenAt: firstSeenAt.addingTimeInterval(60),
                retryCount: 0,
                ownerCursor: 11,
                ownerAggregateSequence: 2,
                eventPBBase64: "second"
            ),
            state: &state
        )

        let stored = state.eventsByMissingKey[missingKey]
        #expect(firstResult == .stored)
        #expect(duplicateResult == .alreadyStored)
        #expect(stored?.count == 1)
        #expect(stored?.first?.conversationID == "conversation-1")
        #expect(stored?.first?.firstSeenAt == firstSeenAt)
        #expect(stored?.first?.retryCount == 1)
        #expect(stored?.first?.ownerCursor == 11)
        #expect(stored?.first?.ownerAggregateSequence == 2)
        #expect(stored?.first?.eventPBBase64 == "second")
    }

    @Test func reducerEnforcesTTLAndConversationLimitWithFullRefreshEffect() {
        let reducer = IMConversationDeferredDomainEventStateReducer()
        let now = Date(timeIntervalSince1970: 1_700_100_000)
        let missingKey = IMDeferredDomainEventMissingKey.conversation("conversation-1")
        let expiredID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        var state = IMConversationDeferredDomainEventState(
            eventsByMissingKey: [
                missingKey: [
                    deferredEvent(
                        eventID: expiredID,
                        conversationID: "conversation-1",
                        missingKey: missingKey,
                        firstSeenAt: now.addingTimeInterval(-(25 * 60 * 60)),
                        retryCount: 0
                    )
                ]
            ],
            fullRefreshConversationIDs: []
        )

        for offset in 0..<201 {
            _ = reducer.store(
                deferredEvent(
                    eventID: UUID(uuidString: String(format: "aaaaaaaa-aaaa-aaaa-aaaa-%012d", offset))!,
                    conversationID: "conversation-1",
                    missingKey: missingKey,
                    firstSeenAt: now.addingTimeInterval(Double(offset)),
                    retryCount: 0
                ),
                state: &state
            )
        }

        let effect = reducer.enforceLimits(
            conversationID: "conversation-1",
            now: now,
            state: &state
        )

        let retained = state.eventsByMissingKey.values.flatMap { $0 }
        #expect(effect.fullRefreshConversationID == "conversation-1")
        #expect(effect.removedEventIDs.contains(expiredID))
        #expect(state.fullRefreshConversationIDs == ["conversation-1"])
        #expect(retained.count == 200)
        #expect(!retained.contains { $0.eventID == expiredID })
        #expect(!retained.contains {
            $0.eventID == UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-000000000000")!
        })
    }

    @Test func reducerClearsFullRefreshConversationAndMatchingDeferredEvents() {
        let reducer = IMConversationDeferredDomainEventStateReducer()
        let conversationKey = IMDeferredDomainEventMissingKey.conversation("conversation-1")
        let messageKey = IMDeferredDomainEventMissingKey.message("message-2")
        var state = IMConversationDeferredDomainEventState(
            eventsByMissingKey: [
                conversationKey: [
                    deferredEvent(
                        eventID: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
                        conversationID: "conversation-1",
                        missingKey: conversationKey,
                        firstSeenAt: Date(timeIntervalSince1970: 1_700_000_000),
                        retryCount: 0
                    )
                ],
                messageKey: [
                    deferredEvent(
                        eventID: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
                        conversationID: "conversation-2",
                        missingKey: messageKey,
                        firstSeenAt: Date(timeIntervalSince1970: 1_700_000_001),
                        retryCount: 0
                    )
                ]
            ],
            fullRefreshConversationIDs: ["conversation-1"]
        )

        let didClear = reducer.clearFullRefreshConversation(
            conversationID: " conversation-1 ",
            state: &state
        )

        #expect(didClear)
        #expect(state.fullRefreshConversationIDs.isEmpty)
        #expect(state.eventsByMissingKey[conversationKey] == nil)
        #expect(state.eventsByMissingKey[messageKey]?.count == 1)
    }

    private func deferredEvent(
        eventID: UUID,
        conversationID: String?,
        missingKey: IMDeferredDomainEventMissingKey,
        firstSeenAt: Date,
        retryCount: Int,
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
}
