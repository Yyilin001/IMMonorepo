import Foundation
import GRDB
import IMV2Core
@testable import IMV2ClientKit
import Testing

@Suite("V2 durable retry wakeups")
struct V2CommandRetrySchedulerTests {
    @Test("non-finite persisted dates and clocks stop before a flush or timer", arguments: [false, true], [Double.nan, -Double.infinity, Double.infinity])
    func invalidRetryDates(clockIsInvalid: Bool, seconds: Double) async throws {
        let changes = AsyncThrowingStream<Void, any Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
        defer { changes.continuation.finish() }
        let probe = InvalidRetryDateProbe()
        let invalid = Date(timeIntervalSince1970: seconds)
        let valid = Date(timeIntervalSince1970: 1000)
        let scheduler = V2CommandRetryScheduler(schedule: .init(nextAttemptAt: { clockIsInvalid ? valid : invalid }, updates: { changes.stream }),
            flush: { await probe.flushed(); throw SchedulerTimeout() }, now: { clockIsInvalid ? invalid : valid })
        await #expect(throws: V2CommandRetrySchedulerError.invalidDate) {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await scheduler.run() }
                group.addTask { try await Task.sleep(for: .seconds(1)); throw SchedulerTimeout() }
                defer { group.cancelAll() }
                _ = try await group.next()
            }
        }
        #expect(await probe.flushCount == 0)
    }

    @Test("a quiet connection retries at the durable deadline without new activity")
    func quietConnectionRetriesAtDeadline() async throws {
        let store = try makeStore()
        let now = Date()
        let command = V2PendingMessageCommand(roomID: .init(uuid: UUID()), clientMessageID: .init(uuid: UUID()), text: "quiet retry", state: .pending, attemptCount: 0, nextAttemptAt: now.addingTimeInterval(0.05), acceptedMessageID: nil, acceptedRoomSequence: nil, terminalCode: nil)
        try await store.enqueue(command)
        let completed = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let worker = Task {
            try await V2CommandRetryScheduler(schedule: store.commandRetrySchedule(lanes: [.messages]), flush: {
                guard let ready = try await store.nextReadyMessage(now: Date()) else { return }
                try await store.markMessageAccepted(clientMessageID: ready.clientMessageID, messageID: .init(uuid: UUID()), roomSequence: 1)
                completed.continuation.yield(())
            }).run()
        }
        defer { worker.cancel(); completed.continuation.finish() }
        try await waitForCompletion(completed.stream)
        #expect(try await store.pendingMessageCommands().first?.state == .accepted)
        worker.cancel()
        _ = await worker.result
    }

    @Test("enqueue racing with sleep registration cannot lose a wakeup and a bounded batch continues")
    func bufferedWakeSurvivesSleepRace() async throws {
        let source = SleepRaceSchedule()
        let completed = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let schedule = V2CommandRetrySchedule(nextAttemptAt: { await source.next() }, updates: { await source.updates() })
        let worker = Task {
            try await V2CommandRetryScheduler(schedule: schedule, flush: {
                if await source.consumeOne() { completed.continuation.yield(()) }
            }).run()
        }
        defer { worker.cancel(); completed.continuation.finish() }
        try await waitForCompletion(completed.stream)
        #expect(await source.flushCount == 3)
        worker.cancel()
        _ = await worker.result
    }

    @Test("a forward chunk waiting for retry is not created again or reported ready")
    func delayedForwardChunkIsNotMaterializedTwice() async throws {
        let store = try makeStore()
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let engine = V2BulkForwardMessagesOutboxEngine(store: store, transport: UnusedForwardTransport(), now: { now })
        _ = try await engine.enqueue(sources: [try testForwardReference(.init(uuid: UUID()))], targetRoomIDs: [.init(uuid: UUID())])
        let chunk = try #require(try await store.nextReadyForwardPlanChunk(now: now))
        let deadline = now.addingTimeInterval(60)
        try await store.scheduleForwardPlanChunkRetry(operationID: chunk.command.operationID, nextAttemptAt: deadline)
        #expect(try await store.nextReadyForwardPlanChunk(now: now) == nil)
        let schedule = store.commandRetrySchedule(lanes: [.forwardPlans])
        #expect(try await schedule.nextAttemptAt() == deadline)
        #expect(try await store.nextReadyForwardPlanChunk(now: deadline)?.command.operationID == chunk.command.operationID)
    }

    @Test("schedule summary uses ready indexes and excludes unregistered lanes")
    func scheduleUsesIndexedMinima() async throws {
        let store = try makeStore()
        let query = GRDBV2LocalSyncStore.commandRetryScheduleQuery(lanes: [.messages, .edits, .forwardPlans])
        let plan = try await store.databasePool.read { db in
            try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + query).map { $0["detail"] as String }
        }
        #expect(plan.contains { $0.contains("v2_pending_message_ready_idx") })
        #expect(plan.contains { $0.contains("v2_pending_message_edits_ready_idx") })
        #expect(plan.contains { $0.contains("v2_forward_message_chunks_ready_idx") })
        let command = V2PendingMessageCommand(roomID: .init(uuid: UUID()), clientMessageID: .init(uuid: UUID()), text: "other lane", state: .pending, attemptCount: 0, nextAttemptAt: Date(), acceptedMessageID: nil, acceptedRoomSequence: nil, terminalCode: nil)
        try await store.enqueue(command)
        #expect(try await store.commandRetrySchedule(lanes: [.edits]).nextAttemptAt() == nil)
    }

    private func makeStore() throws -> GRDBV2LocalSyncStore {
        try .init(databaseURL: FileManager.default.temporaryDirectory.appending(path: "im-retry-schedule-\(UUID()).sqlite"), installationBinding: .init(value: UUID()))
    }
    private func waitForCompletion(_ events: AsyncStream<Void>) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { for await _ in events { return }; throw CancellationError() }
            group.addTask { try await Task.sleep(for: .seconds(3)); throw SchedulerTimeout() }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }
}

private struct SchedulerTimeout: Error {}
private actor SleepRaceSchedule {
    private var continuation: AsyncThrowingStream<Void, any Error>.Continuation?
    private var initialRead = true
    private(set) var flushCount = 0
    func updates() -> AsyncThrowingStream<Void, any Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation = $0 }
    }
    func next() -> Date? {
        if initialRead {
            initialRead = false
            // The read has decided idle, but a concurrent enqueue commits
            // before the worker can register its wait.
            continuation?.yield(())
            return nil
        }
        return flushCount < 3 ? .distantPast : nil
    }
    func consumeOne() -> Bool { flushCount += 1; return flushCount == 3 }
}
private struct UnusedForwardTransport: V2ClientForwardMessagesTransport {
    func forwardMessages(command: V2ForwardMessagesCommand) async throws -> [V2ForwardMessageResult] { throw SchedulerTimeout() }
}

private actor InvalidRetryDateProbe {
    private(set) var flushCount = 0
    func flushed() { flushCount += 1 }
}
