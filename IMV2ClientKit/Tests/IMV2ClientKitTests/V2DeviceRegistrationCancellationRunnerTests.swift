import Foundation
import IMV2Core
import Testing
@testable import IMV2ClientKit

@Suite("Independent registration cancellation runner", .timeLimit(.minutes(1)))
struct V2DeviceRegistrationCancellationRunnerTests {
    @Test("lost cancellation response retries the original proof after owner recreation")
    func lostResponse() async throws {
        let persistence = DeviceRegistrationTestPersistence()
        let store = V2DeviceRegistrationStore(persistence: persistence)
        try await enqueue(store)
        let now = Date()
        let client = CancellationRunnerClient([.failure(.networkFailure), .result(.cancelled)])
        try await V2DeviceRegistrationCancellationRunner(store: store, client: client, now: { now }).flushOnce()
        let job = try #require(try await store.cancellationJobs().first)
        #expect(job.attempts == 1 && job.nextAttemptAt == now.addingTimeInterval(2))
        try await V2DeviceRegistrationCancellationRunner(store: store, client: client, now: { now }).flushOnce()
        #expect(await client.calls.count == 1)
        let reopened = V2DeviceRegistrationStore(persistence: persistence)
        try await V2DeviceRegistrationCancellationRunner(store: reopened, client: client, now: { now.addingTimeInterval(2) }).flushOnce()
        #expect(try await reopened.cancellationJobs().isEmpty)
        #expect(await client.calls == [job.cancellation, job.cancellation])
    }

    @Test("server expiry settles an old proof; local expiry alone never does")
    func expiry() async throws {
        let store = V2DeviceRegistrationStore(persistence: DeviceRegistrationTestPersistence(), now: { Date(timeIntervalSince1970: 1) })
        try await enqueue(store)
        let client = CancellationRunnerClient([.result(.expired)])
        try await V2DeviceRegistrationCancellationRunner(store: store, client: client).flushOnce()
        #expect(await client.calls.count == 1)
        #expect(try await store.cancellationJobs().isEmpty)
    }

    @Test("retry hints are bounded and invalid requests pause", arguments: [V2DeviceRegistrationCancellationClientError.rateLimited(retryAfterSeconds: 120), .rateLimited(retryAfterSeconds: Int.max), .serverStatus(503), .serverStatus(400), .invalidResponse])
    func errors(_ error: V2DeviceRegistrationCancellationClientError) async throws {
        let store = V2DeviceRegistrationStore(persistence: DeviceRegistrationTestPersistence())
        try await enqueue(store)
        let now = Date()
        try await V2DeviceRegistrationCancellationRunner(store: store, client: CancellationRunnerClient([.failure(error)]), now: { now }).flushOnce()
        let job = try #require(try await store.cancellationJobs().first)
        switch error {
        case .rateLimited(let seconds): #expect(job.nextAttemptAt == now.addingTimeInterval(seconds == 120 ? 120 : 86_400))
        case .serverStatus(503): #expect(job.nextAttemptAt == now.addingTimeInterval(2))
        case .serverStatus(400): #expect(job.pauseReason == .invalidRequest)
        case .invalidResponse: #expect(job.pauseReason == .invalidResponse)
        default: Issue.record("Unexpected fixture")
        }
        #expect(job.attempts == 1)
    }

    @Test("a failed job does not stop other jobs and each flush is bounded")
    func boundedIsolation() async throws {
        let store = V2DeviceRegistrationStore(persistence: DeviceRegistrationTestPersistence())
        for index in 0..<6 { _ = try await store.prepare(accountHandle: "account_\(index)") }
        try await store.discardPendingRegistrations()
        let client = CancellationRunnerClient([.failure(.serverStatus(400)), .result(.cancelled), .failure(.networkFailure), .result(.cancelled)])
        try await V2DeviceRegistrationCancellationRunner(store: store, client: client).flushOnce()
        #expect(await client.calls.count == 4)
        let jobs = try await store.cancellationJobs()
        #expect(jobs.count == 4 && jobs.filter { $0.attempts == 1 }.count == 2)
        #expect(jobs.filter { $0.pauseReason == .invalidRequest }.count == 1)
    }

    @Test("idle observation discovers new abandoned proofs and automatically retries")
    func observesWork() async throws {
        let store = V2DeviceRegistrationStore(persistence: DeviceRegistrationTestPersistence())
        let client = CancellationRunnerClient([.failure(.networkFailure), .result(.cancelled)])
        let runner = V2DeviceRegistrationCancellationRunner(store: store, client: client)
        let task = Task { try await runner.run() }
        defer { task.cancel() }
        try await Task.sleep(for: .milliseconds(10))
        try await enqueue(store)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(try await store.cancellationJobs().isEmpty), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(try await store.cancellationJobs().isEmpty)
        #expect(await client.calls.count == 2)
        task.cancel()
        _ = await task.result
    }

    @Test("cancelled in-flight response cannot complete work or overlap another run")
    func drainsCancellation() async throws {
        let store = V2DeviceRegistrationStore(persistence: DeviceRegistrationTestPersistence())
        try await enqueue(store)
        let original = try await store.cancellationJobs()
        let client = SuspendedCancellationClient()
        let runner = V2DeviceRegistrationCancellationRunner(store: store, client: client)
        let task = Task { try await runner.run() }
        await client.waitForRequest()
        task.cancel()
        await #expect(throws: V2DeviceRegistrationCancellationRunnerError.alreadyRunning) { try await runner.run() }
        await client.release()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try await store.cancellationJobs() == original)
    }

    @Test("failed local completion keeps the exact proof for another confirmed replay")
    func completionFailure() async throws {
        let persistence = DeviceRegistrationTestPersistence()
        let store = V2DeviceRegistrationStore(persistence: persistence)
        try await enqueue(store)
        let original = try await store.cancellationJobs()
        persistence.setFailure(.delete)
        let client = CancellationRunnerClient([])
        let runner = V2DeviceRegistrationCancellationRunner(store: store, client: client)
        await #expect(throws: V2DeviceCredentialRegistrationOperationStoreError.unavailable) { try await runner.flushOnce() }
        persistence.setFailure(nil)
        #expect(try await store.cancellationJobs() == original)
        try await runner.flushOnce()
        #expect(try await store.cancellationJobs().isEmpty)
        #expect(await client.calls.count == 2)
    }

    private func enqueue(_ store: V2DeviceRegistrationStore) async throws {
        _ = try await store.prepare(accountHandle: "test_account")
        try await store.discardPendingRegistrations()
    }
}

private actor CancellationRunnerClient: V2DeviceRegistrationCancellationClient {
    enum Outcome: Sendable { case result(V2DeviceRegistrationCancellationResult), failure(V2DeviceRegistrationCancellationClientError) }
    private var outcomes: [Outcome]
    private(set) var calls: [V2DeviceRegistrationCancellation] = []
    init(_ outcomes: [Outcome]) { self.outcomes = outcomes }
    func cancel(_ request: V2DeviceRegistrationCancellation) throws -> V2DeviceRegistrationCancellationResult {
        calls.append(request)
        switch outcomes.isEmpty ? .result(.cancelled) : outcomes.removeFirst() {
        case .result(let value): return value
        case .failure(let error): throw error
        }
    }
}

private actor SuspendedCancellationClient: V2DeviceRegistrationCancellationClient {
    private var entered = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    func cancel(_ request: V2DeviceRegistrationCancellation) async -> V2DeviceRegistrationCancellationResult {
        entered = true; observer?.resume(); observer = nil
        await withCheckedContinuation { waiter = $0 }
        return .cancelled
    }
    func waitForRequest() async {
        if entered { return }
        await withCheckedContinuation { observer = $0 }
    }
    func release() { waiter?.resume(); waiter = nil }
}
