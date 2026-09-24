import Foundation
import IMV2Core
import Testing
@testable import IMV2ClientKit

@Suite("Registration cancellation recovery", .timeLimit(.minutes(1)))
struct V2RegistrationCancellationRecoveryTests {
    @Test("cold recovery retires owned finalizers and abandons only unowned attempts", arguments: ["owned", "other", "logout", "absent"])
    func coldOwnership(_ scenario: String) async throws {
        let persistence = DeviceRegistrationTestPersistence()
        let store = V2DeviceRegistrationStore(persistence: persistence)
        let lease = try await store.prepare(accountHandle: "first_account")
        let pending = try #require(try await lease.load())
        let other = try await store.prepare(accountHandle: "second_account")
        let otherPending = try #require(try await other.load())
        let credentials = try V2AuthCredentials(userID: .init(UUID().uuidString),
            deviceID: scenario == "other" ? .init(UUID().uuidString) : pending.deviceID,
            accessToken: "local-access", accessTokenExpiresAt: .distantFuture, refreshCredential: "local-refresh",
            revocationCredential: .generate(), revocationCredentialExpiresAt: .distantFuture)
        let record = V2AuthCredentialRecord(credentials: credentials,
            pendingRevocationOperationID: scenario == "logout" ? UUID() : nil)
        let owner = scenario == "absent" ? nil : record
        let before = try persistence.load()
        persistence.setFailure(.save)
        await #expect(throws: V2DeviceCredentialRegistrationOperationStoreError.unavailable) { try await store.recoverUnclaimed(ownedBy: owner) }
        persistence.setFailure(nil)
        #expect(try persistence.load() == before)
        try await store.recoverUnclaimed(ownedBy: owner)
        let cancellations = try await V2DeviceRegistrationStore(persistence: persistence).pendingCancellations()
        #expect(cancellations.contains(otherPending.cancellation))
        #expect(cancellations.contains(pending.cancellation) == (scenario != "owned"))
        try await lease.delete()
        #expect(try await store.pendingCancellations() == cancellations)
        let next = try await store.prepare(accountHandle: "first_account")
        #expect(try await next.deviceID() != pending.deviceID)
    }

    @Test("paused retry preserves backoff jobs and stale completions cannot erase new progress")
    func retryAndCompare() async throws {
        let persistence = DeviceRegistrationTestPersistence()
        let store = V2DeviceRegistrationStore(persistence: persistence)
        _ = try await store.prepare(accountHandle: "first_account")
        _ = try await store.prepare(accountHandle: "second_account")
        try await store.discardPendingRegistrations()
        let original = try await store.cancellationJobs()
        try await store.recordCancellationFailure(original[0], retryAt: .distantFuture, pauseReason: .invalidResponse)
        try await store.recordCancellationFailure(original[1], retryAt: .distantFuture)
        let before = try await store.cancellationJobs()
        persistence.setFailure(.save)
        await #expect(throws: V2DeviceCredentialRegistrationOperationStoreError.unavailable) { try await store.retryPausedCancellations() }
        persistence.setFailure(nil)
        #expect(try await store.cancellationJobs() == before)
        try await store.retryPausedCancellations()
        let resumed = try await store.cancellationJobs()
        #expect(resumed[0].attempts == 1 && resumed[0].cancellation == original[0].cancellation && resumed[0].pauseReason == nil)
        #expect(resumed[1] == before[1])
        try await store.completeCancellationJob(before[0])
        try await store.recordCancellationFailure(original[0], retryAt: .distantFuture, pauseReason: .invalidRequest)
        #expect(try await store.cancellationJobs() == resumed)
        var iterator = await store.cancellationStatusUpdates().makeAsyncIterator()
        #expect(try await iterator.next() == .pending)
        try await store.recordCancellationFailure(resumed[0], retryAt: .distantFuture, pauseReason: .invalidRequest)
        #expect(try await iterator.next() == .paused)
        try await store.completeCancellationJob(try #require(try await store.cancellationJobs().first))
        try await store.completeCancellationJob(resumed[1])
        #expect(try await iterator.next() == .empty)
    }
}
