import Foundation
import Testing
@testable import IMV2ClientKit

@Suite("Revocation status and explicit recovery")
struct V2DeviceRevocationRecoveryTests {
    @Test("snapshots coalesce to current aggregate state and never expose proof")
    func observesStatus() async throws {
        let store = V2DeviceRevocationStore(persistence: RevocationTestPersistence())
        var updates = await store.statusUpdates().makeAsyncIterator()
        #expect(try await updates.next() == .empty)
        let intent = try intent()
        try await store.enqueue(intent)
        #expect(try await updates.next() == .pending)
        let job = try #require(try await store.jobs().first)
        try await store.recordFailure(job, retryAt: .distantFuture, pauseReason: .operationConflict)
        #expect(try await updates.next() == .paused)
        try await store.retryPaused()
        let resumed = try #require(try await store.jobs().first)
        #expect(resumed.intent == intent)
        #expect(resumed.attempts == 1)
        #expect(resumed.pauseReason == nil)
        #expect(try await store.complete(job) == false)
        try await store.complete(resumed)
        // Pending was superseded before the consumer read it.
        #expect(try await updates.next() == .empty)
    }

    @Test("explicit retry preserves backoff, is idempotent and persists across owners")
    func retryPreservesBackoff() async throws {
        let persistence = RevocationTestPersistence()
        let store = V2DeviceRevocationStore(persistence: persistence)
        try await store.enqueue(intent())
        try await store.enqueue(intent())
        let jobs = try await store.jobs()
        try await store.recordFailure(jobs[0], retryAt: .distantFuture)
        try await store.recordFailure(jobs[1], retryAt: .distantFuture, pauseReason: .invalidResponse)
        let before = try await store.jobs()
        persistence.setFailure(.save)
        await #expect(throws: V2DeviceRevocationStoreError.unavailable) { try await store.retryPaused() }
        persistence.setFailure(nil)
        #expect(try await store.jobs() == before)
        try await store.retryPaused()
        let after = try await store.jobs()
        #expect(after[0] == before[0])
        #expect(after[1].intent == before[1].intent)
        #expect(after[1].attempts == before[1].attempts)
        #expect(after[1].nextAttemptAt == .distantPast)
        try await store.retryPaused()
        #expect(try await V2DeviceRevocationStore(persistence: persistence).jobs() == after)
        #expect(try await store.due(at: Date()).count == 1)
    }

    @Test("unreadable status fails closed and a new subscription recovers")
    func unavailableStatus() async throws {
        let persistence = RevocationTestPersistence()
        let store = V2DeviceRevocationStore(persistence: persistence)
        persistence.setFailure(.load)
        var failed = await store.statusUpdates().makeAsyncIterator()
        await #expect(throws: V2DeviceRevocationStoreError.unavailable) { try await failed.next() }
        persistence.setFailure(nil)
        var recovered = await store.statusUpdates().makeAsyncIterator()
        #expect(try await recovered.next() == .empty)
    }

    private func intent() throws -> V2DeviceRevocationIntent {
        .init(credentials: try .init(userID: .init(UUID().uuidString), deviceID: .init(UUID().uuidString),
            accessToken: "access", accessTokenExpiresAt: .distantFuture, refreshCredential: "refresh",
            revocationCredential: .generate(), revocationCredentialExpiresAt: .distantFuture), operationID: UUID())
    }
}
