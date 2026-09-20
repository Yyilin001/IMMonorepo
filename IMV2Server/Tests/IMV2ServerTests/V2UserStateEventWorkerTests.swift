import Foundation
import IMV2Core
@testable import IMV2Server
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

    private func fixture() throws -> V2UserStateEvent {
        try .init(sourceEventID: .init(uuid: UUID()), userID: .init(uuid: UUID()), kind: .ownReadWatermark,
                  payload: Data("{}".utf8), createdAt: Date(timeIntervalSince1970: 1_750_000_000))
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
