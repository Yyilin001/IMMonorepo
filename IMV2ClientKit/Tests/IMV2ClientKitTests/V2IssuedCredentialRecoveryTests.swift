import Foundation
import IMV2Core
import Synchronization
import Testing
@testable import IMV2ClientKit

@Suite("Received credential recovery", .timeLimit(.minutes(1)))
struct V2IssuedCredentialRecoveryTests {
    @Test("cold recovery relinquishes unadopted results and retains only purpose-limited proof")
    func recoversUnadopted() async throws {
        let persistence = IssuedRecoveryTestPersistence()
        let queue = V2DeviceRevocationStore(persistence: RevocationTestPersistence())
        let first = V2IssuedCredentialRecoveryStore(persistence: persistence, revocations: queue)
        let credentials = try credentials()
        let receipt = try await first.receive(credentials, operationID: UUID())
        let raw = String(decoding: try #require(try persistence.load()), as: UTF8.self)
        #expect(!raw.contains(credentials.accessToken))
        #expect(!raw.contains(credentials.refreshCredential))
        #expect(!raw.contains("accessToken"))
        #expect(try await queue.jobs().isEmpty)
        let reopened = V2IssuedCredentialRecoveryStore(persistence: persistence, revocations: queue)
        try await reopened.recoverUnclaimed(ownedBy: nil)
        #expect(try await queue.jobs().first?.intent == receipt)
        #expect(try persistence.load() == nil)
    }

    @Test("cold recovery recognizes adoption but pending logout still relinquishes", arguments: [false, true])
    func recognizesDurableAdoption(pendingLogout: Bool) async throws {
        let persistence = IssuedRecoveryTestPersistence()
        let queue = V2DeviceRevocationStore(persistence: RevocationTestPersistence())
        let credentials = try credentials()
        let first = V2IssuedCredentialRecoveryStore(persistence: persistence, revocations: queue)
        let receipt = try await first.receive(credentials, operationID: UUID())
        let owned = V2AuthCredentialRecord(credentials: credentials, pendingRevocationOperationID: pendingLogout ? UUID() : nil)
        try await V2IssuedCredentialRecoveryStore(persistence: persistence, revocations: queue).recoverUnclaimed(ownedBy: owned)
        #expect(try persistence.load() == nil)
        #expect(try await queue.jobs().map(\.intent) == (pendingLogout ? [receipt] : []))
    }

    @Test("failed queue handoff is durable and cannot later be adopted")
    func retriesAbandoned() async throws {
        let persistence = IssuedRecoveryTestPersistence()
        let queuePersistence = RevocationTestPersistence()
        let queue = V2DeviceRevocationStore(persistence: queuePersistence)
        let recovery = V2IssuedCredentialRecoveryStore(persistence: persistence, revocations: queue)
        let receipt = try await recovery.receive(credentials(), operationID: UUID())
        queuePersistence.setFailure(.save)
        await #expect(throws: V2DeviceRevocationStoreError.unavailable) { try await recovery.abandon(receipt) }
        #expect(try persistence.load() != nil)
        await #expect(throws: V2IssuedCredentialRecoveryError.conflict) { try await recovery.adopt(receipt) }
        queuePersistence.setFailure(nil)
        try await V2IssuedCredentialRecoveryStore(persistence: persistence, revocations: queue).drainAbandoned()
        #expect(try await queue.jobs().first?.intent == receipt)
        #expect(try persistence.load() == nil)
        await #expect(throws: V2IssuedCredentialRecoveryError.conflict) { try await recovery.adopt(receipt) }
    }

    @Test("recovery converges with existing logout without resetting operation or pause")
    func preservesExistingLogout() async throws {
        let persistence = IssuedRecoveryTestPersistence()
        let queue = V2DeviceRevocationStore(persistence: RevocationTestPersistence())
        let credentials = try credentials()
        try await queue.enqueue(.init(credentials: credentials, operationID: UUID()))
        let original = try #require(try await queue.jobs().first)
        try await queue.recordFailure(original, retryAt: .distantFuture, pauseReason: .invalidResponse)
        let expected = try await queue.jobs()
        let recovery = V2IssuedCredentialRecoveryStore(persistence: persistence, revocations: queue)
        let receipt = try await recovery.receive(credentials, operationID: UUID())
        try await recovery.abandon(receipt)
        #expect(try await queue.jobs() == expected)
        #expect(try persistence.load() == nil)
    }

    @Test("receipt deletion failure preserves replayable work after queue confirmation")
    func retriesAfterLocalDeletionFailure() async throws {
        let persistence = IssuedRecoveryTestPersistence()
        let queue = V2DeviceRevocationStore(persistence: RevocationTestPersistence())
        let recovery = V2IssuedCredentialRecoveryStore(persistence: persistence, revocations: queue)
        let receipt = try await recovery.receive(credentials(), operationID: UUID())
        persistence.setFailure(.delete)
        await #expect(throws: V2IssuedCredentialRecoveryError.unavailable) { try await recovery.abandon(receipt) }
        let job = try #require(try await queue.jobs().first)
        #expect(try await queue.complete(job))
        persistence.setFailure(nil)
        try await recovery.drainAbandoned()
        #expect(try await queue.jobs().first?.intent == receipt)
        #expect(try persistence.load() == nil)
    }

    @Test("unavailable, conflicting and malformed receipts fail closed")
    func rejectsInvalidStorage() async throws {
        let persistence = IssuedRecoveryTestPersistence()
        let recovery = V2IssuedCredentialRecoveryStore(persistence: persistence,
            revocations: V2DeviceRevocationStore(persistence: RevocationTestPersistence()))
        let credentials = try credentials()
        let operationID = UUID()
        persistence.setFailure(.save)
        await #expect(throws: V2IssuedCredentialRecoveryError.unavailable) { try await recovery.receive(credentials, operationID: operationID) }
        persistence.setFailure(nil)
        #expect(try persistence.load() == nil)
        let receipt = try await recovery.receive(credentials, operationID: operationID)
        #expect(try await recovery.receive(credentials, operationID: operationID) == receipt)
        await #expect(throws: V2IssuedCredentialRecoveryError.conflict) { try await recovery.receive(self.credentials(), operationID: operationID) }
        try await recovery.adopt(receipt)
        #expect(try persistence.load() == nil)
        try persistence.save(Data("invalid-json".utf8))
        await #expect(throws: V2IssuedCredentialRecoveryError.malformedRecord) { try await recovery.recoverUnclaimed(ownedBy: nil) }
        #expect(try persistence.load() == Data("invalid-json".utf8))
    }

    private func credentials() throws -> V2AuthCredentials {
        try .init(userID: .init(UUID().uuidString), deviceID: .init(UUID().uuidString),
            accessToken: "private-access-marker", accessTokenExpiresAt: .distantFuture,
            refreshCredential: "private-refresh-marker", revocationCredential: .generate(), revocationCredentialExpiresAt: .distantFuture)
    }
}

final class IssuedRecoveryTestPersistence: V2IssuedCredentialRecoveryPersisting {
    enum Operation: Sendable { case load, save, delete }
    private struct State { var data: Data?; var failure: Operation? }
    private let state = Mutex(State())
    func setFailure(_ operation: Operation?) { state.withLock { $0.failure = operation } }
    func load() throws -> Data? {
        try state.withLock { state in
            guard state.failure != .load else { throw V2IssuedCredentialRecoveryError.unavailable }
            return state.data
        }
    }
    func save(_ data: Data) throws {
        try state.withLock { state in
            guard state.failure != .save else { throw V2IssuedCredentialRecoveryError.unavailable }
            state.data = data
        }
    }
    func delete() throws {
        try state.withLock { state in
            guard state.failure != .delete else { throw V2IssuedCredentialRecoveryError.unavailable }
            state.data = nil
        }
    }
}
