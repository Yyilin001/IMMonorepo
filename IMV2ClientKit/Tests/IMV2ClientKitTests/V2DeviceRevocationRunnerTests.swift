import Foundation
import IMV2Core
import Testing
@testable import IMV2ClientKit

@Suite("Independent revocation runner", .timeLimit(.minutes(1)))
struct V2DeviceRevocationRunnerTests {
    @Test("lost response survives owner restart with the original proof and operation")
    func lostResponse() async throws {
        let persistence = RevocationTestPersistence()
        let store = V2DeviceRevocationStore(persistence: persistence)
        let intent = try intent()
        try await store.enqueue(intent)
        let now = Date(timeIntervalSince1970: 100)
        let client = RevocationRunnerClient([.failure(.networkFailure), .result(.revoked)])
        try await V2DeviceRevocationRunner(store: store, client: client, now: { now }).flushOnce()
        let job = try #require(try await store.jobs().first)
        #expect(job.attempts == 1)
        #expect(job.nextAttemptAt == now.addingTimeInterval(2))
        try await V2DeviceRevocationRunner(store: store, client: client, now: { now }).flushOnce()
        #expect(await client.calls.count == 1)
        let resumed = V2DeviceRevocationStore(persistence: persistence)
        try await V2DeviceRevocationRunner(store: resumed, client: client, now: { now.addingTimeInterval(2) }).flushOnce()
        let calls = await client.calls
        #expect(calls.count == 2)
        #expect(calls[0] == calls[1])
        #expect(calls[0].operationID == intent.operationID)
        #expect(calls[0].credential == intent.credential)
        #expect(try await resumed.jobs().isEmpty)
    }

    @Test("recognized server outcomes either settle or persist a pause", arguments: [V2DeviceRevocationResult.revoked, .expired, .invalidCredential, .operationConflict])
    func serverOutcomes(_ result: V2DeviceRevocationResult) async throws {
        let store = V2DeviceRevocationStore(persistence: RevocationTestPersistence())
        try await store.enqueue(intent())
        let client = RevocationRunnerClient([.result(result)])
        try await V2DeviceRevocationRunner(store: store, client: client).flushOnce()
        let jobs = try await store.jobs()
        switch result {
        case .revoked, .expired: #expect(jobs.isEmpty)
        case .invalidCredential: #expect(jobs.first?.pauseReason == .invalidCredential)
        case .operationConflict: #expect(jobs.first?.pauseReason == .operationConflict)
        }
        #expect(try await store.due(at: .distantFuture).isEmpty)
    }

    @Test("retry hints are bounded and invalid requests pause", arguments: [V2DeviceRevocationClientError.rateLimited(retryAfterSeconds: 120), .rateLimited(retryAfterSeconds: Int.max), .serverStatus(503), .serverStatus(403), .invalidResponse])
    func errorMapping(_ error: V2DeviceRevocationClientError) async throws {
        let store = V2DeviceRevocationStore(persistence: RevocationTestPersistence())
        try await store.enqueue(intent())
        let now = Date(timeIntervalSince1970: 100)
        try await V2DeviceRevocationRunner(store: store, client: RevocationRunnerClient([.failure(error)]), now: { now }).flushOnce()
        let job = try #require(try await store.jobs().first)
        switch error {
        case .rateLimited(let seconds):
            #expect(job.nextAttemptAt == now.addingTimeInterval(seconds == 120 ? 120 : 86_400))
            #expect(job.pauseReason == nil)
        case .serverStatus(503): #expect(job.nextAttemptAt == now.addingTimeInterval(2))
        case .serverStatus(403): #expect(job.pauseReason == .invalidRequest)
        case .invalidResponse: #expect(job.pauseReason == .invalidResponse)
        default: Issue.record("Unexpected fixture outcome")
        }
    }

    @Test("one rejected or offline job does not block other devices")
    func isolatesJobs() async throws {
        let store = V2DeviceRevocationStore(persistence: RevocationTestPersistence())
        for _ in 0..<4 { try await store.enqueue(intent()) }
        let client = RevocationRunnerClient([.result(.invalidCredential), .result(.revoked), .failure(.networkFailure), .result(.revoked)])
        try await V2DeviceRevocationRunner(store: store, client: client).flushOnce()
        let remaining = try await store.jobs()
        #expect(await client.calls.count == 4)
        #expect(remaining.count == 2)
        #expect(remaining.filter { $0.pauseReason == .invalidCredential }.count == 1)
        #expect(remaining.allSatisfy { $0.attempts == 1 })
    }

    @Test("an idle runner discovers later enqueue and retries without a new account event")
    func idleWakeAndAutomaticRetry() async throws {
        let store = V2DeviceRevocationStore(persistence: RevocationTestPersistence())
        let client = RevocationRunnerClient([.failure(.networkFailure), .result(.revoked)])
        let runner = V2DeviceRevocationRunner(store: store, client: client)
        let task = Task { try await runner.run() }
        defer { task.cancel() }
        try await Task.sleep(for: .milliseconds(10))
        try await store.enqueue(intent())
        try await waitForCalls(client, count: 2)
        task.cancel()
        _ = await task.result
        // Cancellation after the response can legitimately leave replayable
        // work; drain it in a subsequent owner and ensure no task was lost.
        try await V2DeviceRevocationRunner(store: store, client: client).flushOnce()
        #expect(try await store.jobs().isEmpty)
    }

    @Test("cancelled late response retains work and a second run cannot overlap the flight")
    func cancellationDrainsOwner() async throws {
        let store = V2DeviceRevocationStore(persistence: RevocationTestPersistence())
        try await store.enqueue(intent())
        let client = SuspendedRevocationClient()
        let runner = V2DeviceRevocationRunner(store: store, client: client)
        let task = Task { try await runner.run() }
        await client.waitForRequest()
        task.cancel()
        await #expect(throws: V2DeviceRevocationRunnerError.alreadyRunning) { try await runner.run() }
        await client.release()
        await #expect(throws: CancellationError.self) { try await task.value }
        let job = try #require(try await store.jobs().first)
        #expect(job.attempts == 0)
        #expect(job.pauseReason == nil)
        let resumedClient = RevocationRunnerClient([.result(.revoked)])
        try await V2DeviceRevocationRunner(store: store, client: resumedClient).flushOnce()
        #expect(try await store.jobs().isEmpty)
    }

    @Test("failure to persist a server confirmation keeps replayable work")
    func failedLocalCompletion() async throws {
        let persistence = RevocationTestPersistence()
        let store = V2DeviceRevocationStore(persistence: persistence)
        try await store.enqueue(intent())
        let original = try await store.jobs()
        persistence.setFailure(.delete)
        let client = RevocationRunnerClient([.result(.revoked), .result(.revoked)])
        let runner = V2DeviceRevocationRunner(store: store, client: client)
        await #expect(throws: V2DeviceRevocationStoreError.unavailable) { try await runner.flushOnce() }
        persistence.setFailure(nil)
        #expect(try await store.jobs() == original)
        try await runner.flushOnce()
        #expect(try await store.jobs().isEmpty)
        #expect(await client.calls.first == client.calls.last)
    }

    private func intent() throws -> V2DeviceRevocationIntent {
        .init(credentials: try .init(userID: .init(UUID().uuidString), deviceID: .init(UUID().uuidString),
            accessToken: "unused-access", accessTokenExpiresAt: .distantFuture, refreshCredential: "unused-refresh",
            revocationCredential: .generate(), revocationCredentialExpiresAt: Date(timeIntervalSince1970: 50)), operationID: UUID())
    }
    private func waitForCalls(_ client: RevocationRunnerClient, count: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while await client.calls.count < count, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(await client.calls.count >= count)
    }
}

private actor RevocationRunnerClient: V2DeviceRevocationClient {
    struct Call: Equatable, Sendable { let credential: V2DeviceRevocationCredential; let operationID: UUID }
    enum Outcome: Sendable { case result(V2DeviceRevocationResult), failure(V2DeviceRevocationClientError) }
    private var outcomes: [Outcome]
    private(set) var calls: [Call] = []
    init(_ outcomes: [Outcome]) { self.outcomes = outcomes }
    func revoke(credential: V2DeviceRevocationCredential, operationID: UUID) throws -> V2DeviceRevocationResult {
        calls.append(.init(credential: credential, operationID: operationID))
        let outcome = outcomes.isEmpty ? .result(.revoked) : outcomes.removeFirst()
        switch outcome { case .result(let value): return value; case .failure(let error): throw error }
    }
}

private actor SuspendedRevocationClient: V2DeviceRevocationClient {
    private var entered = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    func revoke(credential: V2DeviceRevocationCredential, operationID: UUID) async -> V2DeviceRevocationResult {
        entered = true; observer?.resume(); observer = nil
        await withCheckedContinuation { waiter = $0 }
        return .revoked
    }
    func waitForRequest() async {
        if entered { return }
        await withCheckedContinuation { observer = $0 }
    }
    func release() { waiter?.resume(); waiter = nil }
}
