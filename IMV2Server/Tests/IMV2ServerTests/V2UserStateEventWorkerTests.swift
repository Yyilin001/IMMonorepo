@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Foundation
import IMV2Core
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
import Testing

@Suite("User state event worker")
struct V2UserStateEventWorkerTests {
    @Test("transient failures keep retrying after the old attempt budget")
    func retriesTransientFailure() async throws {
        let event = try fixture()
        let outbox = UserStateOutboxFake(lease: .init(event: event, token: UUID(), attempt: 100))
        let worker = V2UserStateEventWorker(outbox: outbox, projector: UserStateProjectorFake(failure: .transient),
            retryPolicy: .init(jitterFraction: 0), now: { event.createdAt })
        #expect(try await worker.runOnce(limit: 1) == 0)
        #expect(await outbox.retryDisposition == .retry(at: event.createdAt.addingTimeInterval(60)))
        #expect(await outbox.acknowledgements == 0)
    }

    @Test("identity conflicts pause instead of replacing a delivered user event")
    func pausesIdentityConflict() async throws {
        let event = try fixture()
        let outbox = UserStateOutboxFake(lease: .init(event: event, token: UUID(), attempt: 1))
        let worker = V2UserStateEventWorker(outbox: outbox, projector: UserStateProjectorFake(failure: .conflict))
        #expect(try await worker.runOnce(limit: 1) == 0)
        #expect(await outbox.retryDisposition == .pause)
    }

    @Test("cancellation leaves the source lease recoverable without acknowledgement or retry mutation")
    func cancellationPreservesLease() async throws {
        let outbox = UserStateOutboxFake(lease: .init(event: try fixture(), token: UUID(), attempt: 1))
        let worker = V2UserStateEventWorker(outbox: outbox, projector: UserStateProjectorFake(failure: .cancelled))
        await #expect(throws: CancellationError.self) { _ = try await worker.runOnce(limit: 1) }
        #expect(await outbox.retryDisposition == nil)
        #expect(await outbox.acknowledgements == 0)
    }

    @Test("claims only processing capacity and projects users concurrently")
    func boundsClaimAndProcessesConcurrently() async throws {
        let date = Date(timeIntervalSince1970: 1_750_000_000)
        let leases = try (0..<5).map { _ in
            V2UserStateEventLease(event: try fixture(createdAt: date), token: UUID(), attempt: 1)
        }
        let outbox = MultiUserStateOutboxFake(leases: leases)
        let projector = ConcurrentUserStateProjector()
        let worker = V2UserStateEventWorker(outbox: outbox, projector: projector,
            maxConcurrentUsers: 2, now: { date })

        #expect(try await worker.runOnce(limit: 5) == 5)
        #expect(await outbox.maximumRequestedLimit == 2)
        #expect(await outbox.acknowledgements == 5)
        #expect(await projector.peakConcurrentProjects == 2)
    }

    @Test("does not reclaim an expired lease again in the same pass")
    func stopsAfterLeaseExpiry() async throws {
        let date = Date(timeIntervalSince1970: 1_750_000_000)
        let leases = [V2UserStateEventLease(event: try fixture(createdAt: date), token: UUID(), attempt: 1)]
        let outbox = MultiUserStateOutboxFake(leases: leases)
        let clock = DateSequenceClock([date, date, date.addingTimeInterval(31)])
        let projector = ConcurrentUserStateProjector()
        let worker = V2UserStateEventWorker(outbox: outbox, projector: projector,
            maxConcurrentUsers: 1, now: { clock.now() })

        #expect(try await worker.runOnce(limit: 8) == 0)
        #expect(await outbox.claimCalls == 1)
        #expect(await outbox.acknowledgements == 0)
    }

    private func fixture(createdAt: Date = Date(timeIntervalSince1970: 1_750_000_000)) throws -> V2UserStateEvent {
        try .init(sourceEventID: .init(uuid: UUID()), userID: .init(uuid: UUID()), kind: .ownReadWatermark,
                  payload: Data("{}".utf8), createdAt: createdAt)
    }
}
private actor UserStateOutboxFake: V2UserStateEventOutbox {
    let lease: V2UserStateEventLease
    var retryDisposition: V2DurableRetryDisposition?
    var acknowledgements = 0
    init(lease: V2UserStateEventLease) { self.lease = lease }
    func claim(now: Date, leaseDuration: TimeInterval, limit: Int) -> [V2UserStateEventLease] { [lease] }
    func acknowledge(_ lease: V2UserStateEventLease, sequence: UInt64, now: Date) -> Bool {
        acknowledgements += 1
        return true
    }
    func retry(_ lease: V2UserStateEventLease, disposition: V2DurableRetryDisposition) { retryDisposition = disposition }
}
private struct UserStateProjectorFake: V2UserStateEventProjecting {
    enum Failure { case transient, conflict, cancelled }
    struct TransientFailure: Error {}
    let failure: Failure
    func project(_ event: V2UserStateEvent) throws -> UInt64 {
        switch failure {
        case .transient: throw TransientFailure()
        case .conflict: throw V2UserStateEventError.identityConflict
        case .cancelled: throw CancellationError()
        }
    }
}

private actor MultiUserStateOutboxFake: V2UserStateEventOutbox {
    let leases: [V2UserStateEventLease]
    private var claimedCount = 0
    private(set) var claimCalls = 0
    private(set) var maximumRequestedLimit = 0
    private(set) var acknowledgements = 0
    init(leases: [V2UserStateEventLease]) { self.leases = leases }
    func claim(now: Date, leaseDuration: TimeInterval, limit: Int) -> [V2UserStateEventLease] {
        claimCalls += 1
        maximumRequestedLimit = max(maximumRequestedLimit, limit)
        let batch = Array(leases.dropFirst(claimedCount).prefix(limit))
        claimedCount += batch.count
        return batch
    }
    func acknowledge(_ lease: V2UserStateEventLease, sequence: UInt64, now: Date) -> Bool {
        acknowledgements += 1
        return true
    }
    func retry(_ lease: V2UserStateEventLease, disposition: V2DurableRetryDisposition) {}
}

private final class DateSequenceClock: @unchecked Sendable {
    private let lock = NSLock()
    private let dates: [Date]
    private var index = 0
    init(_ dates: [Date]) { self.dates = dates }
    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        let date = dates[min(index, dates.count - 1)]
        index += 1
        return date
    }
}

private actor ConcurrentUserStateProjector: V2UserStateEventProjecting {
    private var activeProjects = 0
    private(set) var peakConcurrentProjects = 0
    func project(_ event: V2UserStateEvent) async throws -> UInt64 {
        activeProjects += 1
        peakConcurrentProjects = max(peakConcurrentProjects, activeProjects)
        try await Task.sleep(for: .milliseconds(30))
        activeProjects -= 1
        return 1
    }
}
