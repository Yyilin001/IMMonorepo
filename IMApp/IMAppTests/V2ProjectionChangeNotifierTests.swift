import Foundation
import Testing
import IMV2Core
@testable import IMV2ClientKit
@testable import IMApp

@MainActor
@Suite("Projection notification coalescing", .timeLimit(.minutes(1)))
struct V2ProjectionChangeNotifierTests {
    @Test("ordinary bursts use one timer and do not notify unrelated pages")
    func ordinaryBurst() async throws {
        let clock = ProjectionNotificationClock()
        let notifier = V2ProjectionChangeNotifier(sleep: { await clock.sleep($0) })
        var conversations = await notifier.updates(scopes: .conversations).makeAsyncIterator()
        var contacts = await notifier.updates(scopes: .contacts).makeAsyncIterator()
        var privacy = await notifier.updates(scopes: .privacy).makeAsyncIterator()
        #expect((await conversations.next())?.generation == 0)
        #expect((await contacts.next())?.generation == 0)
        #expect((await privacy.next())?.generation == 0)
        for _ in 0..<40 { await notifier.publish(.init(scopes: .conversations, requiresImmediateRefresh: false)) }
        for _ in 0..<20 { await notifier.publish(.init(scopes: .contacts, requiresImmediateRefresh: false)) }
        await clock.waitForSleeps(1)
        #expect(await clock.durations == [.milliseconds(150)])
        await clock.releaseAll()
        #expect((await conversations.next())?.generation == 1)
        #expect((await contacts.next())?.generation == 1)
        await notifier.finish()
        #expect((await privacy.next())?.generation == nil)
        #expect((await conversations.next())?.generation == nil)
    }

    @Test("urgent changes flush the pending union without waiting for the clock")
    func immediateChangeBypassesTimer() async throws {
        let clock = ProjectionNotificationClock()
        let notifier = V2ProjectionChangeNotifier(sleep: { await clock.sleep($0) })
        var conversations = await notifier.updates(scopes: .conversations).makeAsyncIterator()
        var privacy = await notifier.updates(scopes: .privacy).makeAsyncIterator()
        _ = (await conversations.next())?.generation; _ = (await privacy.next())?.generation
        await notifier.publish(.init(scopes: .conversations, requiresImmediateRefresh: false))
        await clock.waitForSleeps(1)
        await notifier.publish(.init(scopes: .privacy, requiresImmediateRefresh: true))
        #expect((await conversations.next())?.generation == 1)
        #expect((await privacy.next())?.generation == 1)
        #expect(await clock.pendingCount == 1)
        await notifier.finish()
        // This clock deliberately returns after cancellation; a late timer
        // completion cannot publish again or reopen a finished subscription.
        await clock.releaseAll()
        #expect((await conversations.next())?.generation == nil)
        var finished = await notifier.updates().makeAsyncIterator()
        #expect((await finished.next())?.generation == nil)
    }

    @Test("a newer ordinary wake cannot downgrade an unconsumed urgent request")
    func bufferedUrgencyIsPreserved() async throws {
        let clock = ProjectionNotificationClock()
        let notifier = V2ProjectionChangeNotifier(sleep: { await clock.sleep($0) })
        var conversations = await notifier.updates(scopes: .conversations).makeAsyncIterator()
        var privacy = await notifier.updates(scopes: .privacy).makeAsyncIterator()
        _ = await conversations.next(); _ = await privacy.next()
        await notifier.publish(.init(scopes: .conversations, requiresImmediateRefresh: true))
        await notifier.publish(.init(scopes: [.conversations, .privacy], requiresImmediateRefresh: false))
        await clock.waitForSleeps(1)
        await clock.releaseAll()
        // Receiving the ordinary privacy wake proves the timer has published
        // before the deliberately stalled conversation consumer resumes.
        let ordinary = try #require(await privacy.next())
        #expect(ordinary.generation == 2 && !ordinary.requiresImmediateRefresh)
        let merged = try #require(await conversations.next())
        #expect(merged.generation == 2 && merged.requiresImmediateRefresh)
        await notifier.finish()
    }

    @Test("room scopes filter detail subscribers and merge safely into global urgent changes")
    func roomScopedRequests() async throws {
        let clock = ProjectionNotificationClock()
        let notifier = V2ProjectionChangeNotifier(sleep: { await clock.sleep($0) })
        var roomA = await notifier.updates(scopes: .conversationTimeline, roomID: "room-a").makeAsyncIterator()
        var roomB = await notifier.updates(scopes: .conversationTimeline, roomID: "room-b").makeAsyncIterator()
        var global = await notifier.updates(scopes: .conversationTimeline).makeAsyncIterator()
        _ = await roomA.next(); _ = await roomB.next(); _ = await global.next()
        await notifier.publish(.init(scopes: .conversationTimeline, requiresImmediateRefresh: false, roomIDs: ["room-a"]))
        await notifier.publish(.init(scopes: .conversationTimeline, requiresImmediateRefresh: true, roomIDs: ["room-b"]))
        #expect((await roomA.next())?.roomIDs == ["room-a", "room-b"])
        #expect((await roomB.next())?.requiresImmediateRefresh == true)
        #expect((await global.next())?.requiresImmediateRefresh == true)

        await notifier.publish(.init(scopes: .conversationTimeline, requiresImmediateRefresh: true))
        #expect((await roomA.next())?.roomIDs == nil)
        #expect((await roomB.next())?.roomIDs == nil)
        await notifier.finish()
    }

    @Test("real committed acceptance is coalesced but withdrawal wakes immediately")
    func productionSQLiteNotifications() async throws {
        let local = try GRDBV2LocalSyncStore(databaseURL: FileManager.default.temporaryDirectory.appending(path: "im-notification-integration-\(UUID().uuidString).sqlite"), installationBinding: .init(value: UUID()))
        let clock = ProjectionNotificationClock()
        let notifier = V2ProjectionChangeNotifier(localStore: local, sleep: { await clock.sleep($0) })
        var conversations = await notifier.updates(scopes: .conversations).makeAsyncIterator()
        #expect((await conversations.next())?.generation == 1)
        var contacts = await notifier.updates(scopes: .contacts).makeAsyncIterator()
        #expect((await contacts.next())?.generation == 1)
        let room = "00000000-0000-0000-0000-000000000220"
        let message = "00000000-0000-0000-0000-000000000001"
        try await apply(local, sequence: 1, payload: [
            "event_type": "message.accepted", "message_id": message, "room_id": room,
            "room_sequence": 1, "timeline_sequence": 1, "message_revision": 1,
            "sender_user_id": "00000000-0000-0000-0000-000000000222", "text": "hello",
            "mention_user_ids": [], "mentions_everyone": false, "server_created_at_ms": 1_750_000_000_000
        ])
        await clock.waitForSleeps(1)
        try await apply(local, sequence: 2, payload: [
            "event_type": "message.withdrawn", "message_id": message, "room_id": room, "message_revision": 2
        ])
        #expect((await conversations.next())?.generation == 2)
        #expect(await clock.pendingCount == 1)
        try await local.close()
        #expect((await contacts.next())?.generation == nil)
        #expect((await conversations.next())?.generation == nil)
        await clock.releaseAll()
    }

    @Test("withdrawal cancels a stale timeline read and removes the visible body")
    func urgentWithdrawalReplacesStaleTimeline() async throws {
        let local = try GRDBV2LocalSyncStore(databaseURL: FileManager.default.temporaryDirectory.appending(path: "im-withdrawal-refresh-\(UUID().uuidString).sqlite"), installationBinding: .init(value: UUID()))
        let room = "00000000-0000-0000-0000-000000000220"
        let message = "00000000-0000-0000-0000-000000000001"
        try await apply(local, sequence: 1, payload: [
            "event_type": "message.accepted", "message_id": message, "room_id": room,
            "room_sequence": 1, "timeline_sequence": 1, "message_revision": 1,
            "sender_user_id": "00000000-0000-0000-0000-000000000222", "text": "private-before-withdrawal",
            "mention_user_ids": [], "mentions_everyone": false, "server_created_at_ms": 1_750_000_000_000
        ])
        let source = CancellableTimelineSource(source: .init(localStore: local, requestLatestVisible: { _ in }))
        let notifier = V2ProjectionChangeNotifier(localStore: local)
        let store = V2ConversationDetailStore(environment: .init(userID: "user", projections: .init(dataSource: source),
            runtime: .init(projectionChangeNotifier: notifier)), context: .init(roomID: room, kind: .direct(accountKind: .regular)))
        await store.refresh()
        #expect(store.messages.first?.text == "private-before-withdrawal")
        await source.arm()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await store.observeProjectionChanges() }
            await source.waitForPause()
            try await apply(local, sequence: 2, payload: [
                "event_type": "message.withdrawn", "message_id": message, "room_id": room, "message_revision": 2
            ])
            await source.waitForCancellation()
            for _ in 0..<250 {
                if store.messages.first?.isWithdrawn == true { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(store.messages.first?.isWithdrawn == true)
            #expect(!store.messages.contains { $0.text == "private-before-withdrawal" })
            #expect(store.messageActionFeedback == nil)
            #expect(await source.requestCount == 3)
            group.cancelAll()
        }
        try await local.close()
    }

    private func apply(_ local: GRDBV2LocalSyncStore, sequence: UInt64, payload: [String: Any]) async throws {
        let record = try V2ClientSyncRecord(sequence: sequence, sourceEventID: .init(UUID().uuidString), projectionKind: "message", payload: JSONSerialization.data(withJSONObject: payload))
        _ = try await local.apply(.init(generation: 1, records: [record], nextSyncToken: .init("token-\(sequence)"), receipt: .init("receipt-\(sequence)"), hasMore: false, capabilityProfile: "base"))
    }
}

actor ProjectionNotificationClock {
    private var sleepers: [CheckedContinuation<Void, Never>] = []
    private var arrivals: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private(set) var durations: [Duration] = []
    var pendingCount: Int { sleepers.count }

    func sleep(_ duration: Duration) async {
        await withCheckedContinuation { continuation in
            durations.append(duration)
            sleepers.append(continuation)
            let ready = arrivals.filter { $0.count <= durations.count }
            arrivals.removeAll { $0.count <= durations.count }
            for waiter in ready { waiter.continuation.resume() }
        }
    }
    func waitForSleeps(_ count: Int) async {
        guard durations.count < count else { return }
        await withCheckedContinuation { arrivals.append((count, $0)) }
    }
    func releaseAll() {
        let ready = sleepers
        sleepers.removeAll()
        for sleeper in ready { sleeper.resume() }
    }
}

private actor CancellableTimelineSource: V2ConversationDataSource {
    let source: V2GRDBConversationDataSource
    private var holdsNext = false
    private var pause: CheckedContinuation<Void, any Error>?
    private var arrivals: [CheckedContinuation<Void, Never>] = []
    private var cancellations: [CheckedContinuation<Void, Never>] = []
    private var cancelled = false
    private(set) var requestCount = 0
    init(source: V2GRDBConversationDataSource) { self.source = source }
    func arm() { holdsNext = true }
    func conversationSummaryPage(for userID: String, isArchived: Bool, before cursor: V2ClientConversationListCursor?, limit: Int) async throws -> V2ConversationListPage {
        try await source.conversationSummaryPage(for: userID, isArchived: isArchived, before: cursor, limit: limit)
    }
    func timelineWindow(in roomID: String, for userID: String, around messageID: String, before: Int, after: Int) async throws -> V2ConversationTimelineLocation {
        try await source.timelineWindow(in: roomID, for: userID, around: messageID, before: before, after: after)
    }
    func timelinePage(in roomID: String, for userID: String, before cursor: V2ConversationTimelineCursor?, limit: Int) async throws -> V2ConversationTimelinePage {
        requestCount += 1
        let page = try await source.timelinePage(in: roomID, for: userID, before: cursor, limit: limit)
        guard holdsNext else { return page }
        holdsNext = false
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                pause = continuation
                for waiter in arrivals { waiter.resume() }
                arrivals.removeAll()
                if Task.isCancelled { cancelPause() }
            }
        }, onCancel: { Task { await self.cancelPause() } })
        return page
    }
    private func cancelPause() {
        guard let pause else { return }
        self.pause = nil; cancelled = true
        pause.resume(throwing: CancellationError())
        for waiter in cancellations { waiter.resume() }
        cancellations.removeAll()
    }
    func waitForPause() async {
        guard pause == nil else { return }
        await withCheckedContinuation { arrivals.append($0) }
    }
    func waitForCancellation() async {
        guard !cancelled else { return }
        await withCheckedContinuation { cancellations.append($0) }
    }
}
