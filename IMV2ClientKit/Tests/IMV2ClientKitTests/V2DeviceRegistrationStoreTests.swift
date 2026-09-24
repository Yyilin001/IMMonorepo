import Foundation
import IMV2Core
import Synchronization
import Testing
@testable import IMV2ClientKit

@Suite("Device registration lifecycle")
struct V2DeviceRegistrationStoreTests {
    @Test("expiry rotates identity atomically while keeping original cancellation proof")
    func expiryRetainsCancellation() async throws {
        let start = Date()
        let clock = Mutex(start)
        let persistence = DeviceRegistrationTestPersistence()
        let store = V2DeviceRegistrationStore(persistence: persistence, now: { clock.withLock { $0 } })
        let first = try await store.prepare(accountHandle: "account_a")
        let original = try #require(try await first.load())
        clock.withLock { $0 = start.addingTimeInterval(601) }
        persistence.setFailure(.save)
        await #expect(throws: V2DeviceCredentialRegistrationOperationStoreError.unavailable) { try await store.prepare(accountHandle: "account_a") }
        persistence.setFailure(nil)
        #expect(try await first.load() == original)
        let next = try await store.prepare(accountHandle: "account_a")
        let current = try #require(try await next.load())
        #expect(current.deviceID != original.deviceID && current.operationID != original.operationID)
        #expect(try await store.pendingCancellations() == [original.cancellation])
        await #expect(throws: V2DeviceCredentialRegistrationOperationStoreError.malformedRecord) { try await first.deviceID() }
        let wrong = try V2DeviceRegistrationCancellation(deviceID: original.deviceID, operationID: original.operationID,
            proof: .generate(), issueBeforeMilliseconds: original.cancellation.issueBeforeMilliseconds)
        try await store.completeCancellation(wrong)
        #expect(try await store.pendingCancellations() == [original.cancellation])
        try await store.completeCancellation(original.cancellation)
        #expect(try await next.load() == current)
        #expect(try await store.pendingCancellations().isEmpty)
    }

    @Test("recreated owners reuse a durable account-scoped device and operation")
    func resumesPendingRegistration() async throws {
        let persistence = DeviceRegistrationTestPersistence()
        let first = try await V2DeviceRegistrationStore(persistence: persistence).prepare(accountHandle: "Account_A")
        let expected = try await first.load()
        let resumed = try await V2DeviceRegistrationStore(persistence: persistence).prepare(accountHandle: "account_a")
        #expect(try await resumed.load() == expected)
        #expect(try await resumed.deviceID() == first.deviceID())
        let raw = try #require(try persistence.load())
        #expect(!String(decoding: raw, as: UTF8.self).contains("account_a"))
    }

    @Test("completed registration is retired and a later login gets a new device")
    func nextLoginGetsFreshIdentity() async throws {
        let persistence = DeviceRegistrationTestPersistence()
        let store = V2DeviceRegistrationStore(persistence: persistence)
        let first = try await store.prepare(accountHandle: "account_a")
        let old = try #require(try await first.load())
        try await first.delete()
        #expect(try persistence.load() == nil)
        let next = try await V2DeviceRegistrationStore(persistence: persistence).prepare(accountHandle: "account_a")
        let new = try #require(try await next.load())
        #expect(old.deviceID != new.deviceID)
        #expect(old.operationID != new.operationID)
    }

    @Test("accounts have separate attempts and a late finalizer preserves newer work")
    func completionIsBoundToAttempt() async throws {
        let store = V2DeviceRegistrationStore(persistence: DeviceRegistrationTestPersistence())
        let firstA = try await store.prepare(accountHandle: "account_a")
        let oldA = try #require(try await firstA.load())
        let b = try await store.prepare(accountHandle: "account_b")
        let pendingB = try #require(try await b.load())
        #expect(oldA.deviceID != pendingB.deviceID)
        try await firstA.delete()
        let nextA = try await store.prepare(accountHandle: "account_a")
        let pendingA = try #require(try await nextA.load())
        try await firstA.delete()
        #expect(try await nextA.load() == pendingA)
        #expect(try await b.load() == pendingB)
    }

    @Test("logout invalidates old leases and their late saves cannot revive them")
    func discardedAttemptCannotRevive() async throws {
        let store = V2DeviceRegistrationStore(persistence: DeviceRegistrationTestPersistence())
        let first = try await store.prepare(accountHandle: "account_a")
        let old = try #require(try await first.load())
        try await store.discardPendingRegistrations()
        #expect(try await store.pendingCancellations() == [old.cancellation])
        let next = try await store.prepare(accountHandle: "account_a")
        let expected = try await next.load()
        await #expect(throws: V2DeviceCredentialRegistrationOperationStoreError.malformedRecord) { try await first.save(old) }
        await #expect(throws: V2DeviceCredentialRegistrationOperationStoreError.malformedRecord) { try await first.deviceID() }
        try await first.delete()
        #expect(try await next.load() == expected)
    }

    @Test("unavailable persistence does not publish identity or lose a completion retry")
    func persistenceFailuresRetainIntent() async throws {
        let persistence = DeviceRegistrationTestPersistence()
        let store = V2DeviceRegistrationStore(persistence: persistence)
        persistence.setFailure(.save)
        await #expect(throws: V2DeviceCredentialRegistrationOperationStoreError.unavailable) { try await store.prepare(accountHandle: "account_a") }
        persistence.setFailure(nil)
        #expect(try persistence.load() == nil)
        let first = try await store.prepare(accountHandle: "account_a")
        let expected = try await first.load()
        persistence.setFailure(.load)
        await #expect(throws: V2DeviceCredentialRegistrationOperationStoreError.unavailable) { try await first.deviceID() }
        persistence.setFailure(.delete)
        await #expect(throws: V2DeviceCredentialRegistrationOperationStoreError.unavailable) { try await first.delete() }
        persistence.setFailure(nil)
        #expect(try await first.load() == expected)
        try await first.delete()
        #expect(try persistence.load() == nil)
    }

    @Test("corrupt and unsupported ledgers fail closed", arguments: [Data("not-json".utf8), Data(#"{"version":1,"pending":{}}"#.utf8), Data(#"{"version":99,"pending":{}}"#.utf8)])
    func corruptLedger(data: Data) async throws {
        let persistence = DeviceRegistrationTestPersistence()
        try persistence.save(data)
        await #expect(throws: V2DeviceCredentialRegistrationOperationStoreError.malformedRecord) {
            try await V2DeviceRegistrationStore(persistence: persistence).prepare(accountHandle: "account_a")
        }
        #expect(try persistence.load() == data)
    }
}

final class DeviceRegistrationTestPersistence: V2DeviceRegistrationPersisting {
    enum Operation: Sendable { case load, save, delete }
    private struct State { var data: Data?; var failure: Operation? }
    private let state = Mutex(State())
    func setFailure(_ operation: Operation?) { state.withLock { $0.failure = operation } }
    func load() throws -> Data? {
        try state.withLock { state in
            guard state.failure != .load else { throw V2DeviceCredentialRegistrationOperationStoreError.unavailable }
            return state.data
        }
    }
    func save(_ data: Data) throws {
        try state.withLock { state in
            guard state.failure != .save else { throw V2DeviceCredentialRegistrationOperationStoreError.unavailable }
            state.data = data
        }
    }
    func delete() throws {
        try state.withLock { state in
            guard state.failure != .delete else { throw V2DeviceCredentialRegistrationOperationStoreError.unavailable }
            state.data = nil
        }
    }
}
