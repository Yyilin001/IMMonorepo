import Foundation
import Synchronization
import IMV2Core
import Testing
@testable import IMV2ServerGateway

@Suite("Fixed account recovery sessions", .timeLimit(.minutes(1)))
struct V2AccountRoomChangeServiceTests {
    @Test("account readiness has no room bootstrap jobs and sessions retire independently")
    func constantReadiness() async throws {
        let service = V2AccountRoomChangeService(), user = UserID(uuid: UUID())
        var tickets: [V2AccountRoomChangeService.Ticket] = []
        for _ in 0..<1000 {
            let ticket = try await service.begin(userID: user, connectionID: UUID(), send: { _ in true }, close: {})
            try await service.reserveReadyResponse(ticket)
            await service.resume(ticket)
            tickets.append(ticket)
        }
        let metrics = await service.initializationMetricsSnapshot()
        #expect(metrics.accounts == 1 && metrics.readyAccounts == 1)
        #expect(metrics.active == 0 && metrics.queued == 0 && metrics.deferred == 0)
        #expect(metrics.completed == 1000 && metrics.retries == 0)
        for ticket in tickets.dropLast() { await service.stop(ticket) }
        #expect(await service.initializationMetricsSnapshot().accounts == 1)
        await service.stop(try #require(tickets.last))
        #expect(await service.initializationMetricsSnapshot().accounts == 0)
        await service.shutdown()
    }

    @Test("invalidation cannot send before an already reserved Ready response")
    func readyWriteBarrier() async throws {
        let service = V2AccountRoomChangeService(), notifications = Mutex(0), closes = Mutex(0)
        let ticket = try await service.begin(userID: .init(uuid: UUID()), connectionID: UUID(),
            send: { _ in notifications.withLock { $0 += 1 }; return true }, close: { closes.withLock { $0 += 1 } })
        try await service.reserveReadyResponse(ticket)
        await service.invalidateCoverage()
        #expect(notifications.withLock { $0 } == 0 && closes.withLock { $0 } == 0)
        await #expect(throws: V2AccountRoomChangeService.Failure.staleConnection) {
            try await service.reserveReadyResponse(ticket)
        }
        await service.resume(ticket)
        try await eventually { closes.withLock { $0 } == 1 }
        #expect(notifications.withLock { $0 } == 1)
        await service.invalidateCoverage(); await service.resume(ticket)
        #expect(notifications.withLock { $0 } == 1 && closes.withLock { $0 } == 1)
        await service.shutdown()
    }

    @Test("an epoch with no Ready reservation closes without sending an unsolicited notification")
    func invalidationBeforeStart() async throws {
        let service = V2AccountRoomChangeService(), closes = Mutex(0)
        _ = try await service.begin(userID: .init(uuid: UUID()), connectionID: UUID(),
            send: { _ in Issue.record("notification preceded Ready"); return true }, close: { closes.withLock { $0 += 1 } })
        await service.invalidateCoverage()
        try await eventually { closes.withLock { $0 } == 1 }
        #expect(await service.initializationMetricsSnapshot().accounts == 0)
        await service.shutdown()
    }

    @Test("a delayed old notification cannot close or resume its replacement epoch")
    func staleWriterCannotRetireReplacement() async throws {
        let service = V2AccountRoomChangeService(), gate = AccountSessionGate(), connection = UUID()
        let user = UserID(uuid: UUID()), closes = Mutex(0), stopped = Mutex(false)
        let old = try await service.begin(userID: user, connectionID: connection,
            send: { _ in await gate.suspend(); return true }, close: { closes.withLock { $0 += 1 } })
        try await service.reserveReadyResponse(old); await service.resume(old)
        await service.invalidate(userID: user)
        await gate.waitUntilSuspended()
        let stop = Task { await service.stop(old); stopped.withLock { $0 = true } }
        try await eventually { await service.initializationMetricsSnapshot().accounts == 0 }
        #expect(!stopped.withLock { $0 })
        let replacement = try await service.begin(userID: user, connectionID: connection, send: { _ in true }, close: {})
        #expect(old.epoch != replacement.epoch)
        await service.resume(old)
        try await service.reserveReadyResponse(replacement)
        await gate.release(); await stop.value
        #expect(closes.withLock { $0 } == 0)
        try await service.reserveReadyResponse(replacement)
        #expect(await service.initializationMetricsSnapshot().readyAccounts == 1)
        await service.shutdown()
    }

    @Test("invalidation targets one account; rejected delivery retires only its epoch", arguments: [false, true])
    func scopedRetirement(writerAccepts: Bool) async throws {
        let service = V2AccountRoomChangeService(), firstUser = UserID(uuid: UUID())
        let firstClosed = Mutex(0), secondClosed = Mutex(0)
        let first = try await service.begin(userID: firstUser, connectionID: UUID(),
            send: { _ in writerAccepts }, close: { firstClosed.withLock { $0 += 1 } })
        let second = try await service.begin(userID: .init(uuid: UUID()), connectionID: UUID(),
            send: { _ in Issue.record("unrelated account invalidated"); return true }, close: { secondClosed.withLock { $0 += 1 } })
        for ticket in [first, second] { try await service.reserveReadyResponse(ticket); await service.resume(ticket) }
        await service.invalidate(userID: firstUser)
        try await eventually { firstClosed.withLock { $0 } == 1 }
        #expect(secondClosed.withLock { $0 } == 0)
        try await service.reserveReadyResponse(second)
        #expect(await service.initializationMetricsSnapshot().accounts == 1)
        await service.shutdown()
        await #expect(throws: V2AccountRoomChangeService.Failure.closed) {
            _ = try await service.begin(userID: firstUser, connectionID: UUID(), send: { _ in true }, close: {})
        }
    }

    private func eventually(_ condition: @Sendable () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !(await condition()) {
            try #require(ContinuousClock.now < deadline, "account session did not settle")
            await Task.yield()
        }
    }
}
private actor AccountSessionGate {
    private var suspended: CheckedContinuation<Void, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    func suspend() async { await withCheckedContinuation { suspended = $0; waiter?.resume(); waiter = nil } }
    func waitUntilSuspended() async {
        if suspended != nil { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func release() { suspended?.resume(); suspended = nil }
}
