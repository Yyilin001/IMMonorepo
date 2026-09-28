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
        try await persistDurableMessage(in: store, roomID: .init(uuid: UUID()), clientMessageID: .init(uuid: UUID()), text: "quiet retry")
        let work = try #require(try await store.dueOperationWork(now: Date(), kinds: [.sendMessage]).first)
        guard case .claimed(let claim) = try await store.claimOperationWork(id: work.id, ownerID: UUID(), action: .submit, now: Date()) else {
            Issue.record("Expected initial durable claim"); return
        }
        let retryAt = Date().addingTimeInterval(0.1)
        try await store.deferOperationWork(claim, until: retryAt, code: "TEST_RESPONSE_LOST")
        let completed = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let worker = Task {
            try await V2CommandRetryScheduler(schedule: store.operationWorkRetrySchedule(kinds: [.sendMessage]), flush: {
                guard let ready = try await store.dueOperationWork(now: Date(), kinds: [.sendMessage]).first else { return }
                #expect(Date() >= retryAt)
                try await store.completeOperationWork(.init(identity: ready.identity, fingerprint: ready.fingerprint,
                    state: .committed, receipt: "confirmed-test-result"), now: Date())
                completed.continuation.yield(())
            }).run()
        }
        defer { worker.cancel(); completed.continuation.finish() }
        try await waitForCompletion(completed.stream)
        #expect(try await store.operationWork(id: work.id)?.execution == .committed)
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

    @Test("public forward work retains original identity while its retry floor is future")
    func delayedForwardChunkIsNotMaterializedTwice() async throws {
        let f=try DurableForwardFixture();defer { f.remove() }
        let store=try f.open()
        let id=try await store.enqueueForwardPlanOperation(f.command,now:f.now)
        guard case .claimed(let claim)=try await store.claimOperationWork(id:id,ownerID:UUID(),action:.submit,now:f.now) else { throw V2OperationWorkError.invalidTransition }
        let deadline=f.now.addingTimeInterval(60)
        try await store.deferOperationWork(claim,until:deadline,code:"NETWORK_UNAVAILABLE")
        #expect(try await store.dueOperationWork(now:f.now,kinds:[.forwardMessage]).isEmpty)
        #expect(try await store.operationWorkRetrySchedule(kinds:[.forwardMessage]).nextAttemptAt()==deadline)
        #expect(try await store.dueOperationWork(now:deadline,kinds:[.forwardMessage]).map(\.id)==[id])
        try await store.close()
    }

    @Test("schedule summary uses ready indexes and excludes unregistered lanes")
    func scheduleUsesIndexedMinima() async throws {
        let store = try makeStore()
        let plan = try await store.databasePool.read { db in
            try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN SELECT MIN(next_action_at) FROM v2_operation_work WHERE scheduling_state IN ('ready','backingOff')").map { $0["detail"] as String }
        }
        #expect(plan.contains { $0.contains("v2_operation_work_due") })
        try await persistDurableMessage(in: store, roomID: .init(uuid: UUID()), clientMessageID: .init(uuid: UUID()), text: "other kind")
        #expect(try await store.operationWorkRetrySchedule(kinds: [.editMessage]).nextAttemptAt() == nil)
        #expect(try await store.operationWorkRetrySchedule(kinds: [.sendMessage]).nextAttemptAt() != nil)
    }

    private func makeStore() throws -> GRDBV2LocalSyncStore {
        try .init(databaseURL: FileManager.default.temporaryDirectory.appending(path: "im-retry-schedule-\(UUID()).sqlite"), installationBinding: .init(value: UUID()), userID: .init("retry-owner"))
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
private actor InvalidRetryDateProbe {
    private(set) var flushCount = 0
    func flushed() { flushCount += 1 }
}
