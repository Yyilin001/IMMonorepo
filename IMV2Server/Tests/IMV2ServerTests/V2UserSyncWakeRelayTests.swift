@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Foundation
import Testing

@Suite("User sync wake relay")
struct V2UserSyncWakeRelayTests {
    @Test("personal sync wake shares typed capacity retry without changing generic backoff",
          arguments: [false, true])
    func userSyncWakeSharesTypedBackpressurePolicy(backpressure: Bool) async throws {
        let userID = "00000000-0000-0000-0000-000000000d44"
        let store = UserSyncWakeStoreFake(userID: userID, attempt: 6)
        let relay = V2UserSyncWakeRelay(store: store,
            publisher: ControlledUserSyncWakePublisher(backpressure: backpressure),
            now: { Date(timeIntervalSince1970: 1_000) })
        #expect(try await relay.runOnce(limit: 1) == .init(claimed: 1, published: 0, retryScheduled: 1))
        let delay = try #require(await store.retryDate()).timeIntervalSince1970 - 1_000
        #expect(backpressure ? (delay >= 1 && delay <= 2) : delay == 30)
        #expect(await store.publicationCount() == 0)
    }

}

private enum UserSyncWakePublisherError: Error { case unavailable }

private actor UserSyncWakeStoreFake: V2UserSyncWakeStore {
    private let lease: V2UserSyncWakeLease
    private var retryAt: Date?
    private var published = 0
    init(userID: String, attempt: Int) {
        lease = .init(wake: .init(userID: userID, highWatermark: 12),
            revision: 1, claimToken: UUID(), attempt: attempt)
    }
    func claimPending(now: Date, leaseDuration: TimeInterval, limit: Int) -> [V2UserSyncWakeLease] { [lease] }
    func markPublished(_ lease: V2UserSyncWakeLease) { published += 1 }
    func scheduleRetry(_ lease: V2UserSyncWakeLease, nextAttemptAt: Date) { retryAt = nextAttemptAt }
    func retryDate() -> Date? { retryAt }
    func publicationCount() -> Int { published }
}

private struct ControlledUserSyncWakePublisher: V2UserSyncWakePublishing {
    let backpressure: Bool
    func publish(_: V2UserSyncWake) async throws {
        if backpressure { throw V2RealtimePublicationBackpressure.peerRPCs }
        throw UserSyncWakePublisherError.unavailable
    }
}
