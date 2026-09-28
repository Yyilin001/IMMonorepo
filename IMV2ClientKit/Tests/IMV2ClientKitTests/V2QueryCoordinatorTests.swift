import Foundation
import XCTest
@testable import IMV2ClientKit

final class V2QueryCoordinatorTests: XCTestCase, @unchecked Sendable {
    private let activation = UUID()
    private func key(account: String = "a", domain: String = "self", generation: UInt64 = 0,
                     consistency: V2QueryReadConsistency = .refresh) -> V2QueryKey {
        .init(scope: .init(accountID: account, authorizationDomain: domain, activationID: activation, generation: generation),
              requestID: "profile", consistency: consistency)
    }
    private func wait(_ predicate: @escaping @Sendable () async -> Bool) async {
        for _ in 0..<10000 { if await predicate() { return }; await Task.yield() }
        XCTFail("Query state did not converge")
    }
    func testSharedQueryIndependentCancellationAndNoResultCache() async throws {
        let queries = V2QueryCoordinator<Int>()
        let gate = QueryTestGate()
        let request = key()
        let a = Task { try await queries.query(request) { await gate.run() } }
        await wait { await queries.snapshot().subscribers == 1 }
        let b = Task { try await queries.query(request) { await gate.run() } }
        await wait { await queries.snapshot().subscribers == 2 }
        a.cancel()
        do { _ = try await a.value; XCTFail("Expected cancellation") } catch is CancellationError {}
        let calls = await gate.calls(); XCTAssertEqual(calls, 1)
        await gate.open(42)
        let result = try await b.value; XCTAssertEqual(result, 42)
        let fresh = try await queries.query(request) { 99 }; XCTAssertEqual(fresh, 99)
        await queries.closeAndDrain()
    }
    func testLastCancellationRetainsPhysicalSlotUntilRealDrain() async throws {
        let queries = V2QueryCoordinator<Int>(configuration: .init(maximumFlights: 1))
        let gate = QueryTestGate()
        let request = key()
        let first = Task { try await queries.query(request) { await gate.run() } }
        await wait { await gate.calls() == 1 }
        first.cancel()
        do { _ = try await first.value; XCTFail("Expected cancellation") } catch is CancellationError {}
        let state = await queries.snapshot(); XCTAssertEqual(state.flights, 1); XCTAssertEqual(state.subscribers, 0)
        do { _ = try await queries.query(request) { 2 }; XCTFail("Expected overload while old I/O drains") }
        catch V2QueryCoordinator<Int>.QueryError.overloaded {}
        await gate.open(1)
        await wait { await queries.snapshot().flights == 0 }
        let next = try await queries.query(request) { 2 }; XCTAssertEqual(next, 2)
        await queries.closeAndDrain()
    }
    func testAccountAuthorizationActivationGenerationAndAuthorityNeverMerge() async throws {
        let queries = V2QueryCoordinator<Int>()
        let gate = QueryTestGate()
        var requests = [key(), key(account: "b"), key(domain: "another"), key(generation: 1),
                        key(consistency: .authority(minimumRevision: nil)), key(consistency: .authority(minimumRevision: 12))]
        requests.append(.init(scope: .init(accountID: "a", authorizationDomain: "self", activationID: UUID()), requestID: "profile"))
        var tasks: [Task<Int, any Error>] = []
        for request in requests { tasks.append(Task { try await queries.query(request) { await gate.run() } }) }
        let expected = requests.count
        await wait { await gate.calls() == expected }
        let state = await queries.snapshot(); XCTAssertEqual(state.flights, expected)
        await gate.open(7)
        for task in tasks { let result = try await task.value; XCTAssertEqual(result, 7) }
        await queries.closeAndDrain()
    }
    func testSubscriberCapacityAndScopeInvalidationKeepPhysicalOwnership() async throws {
        let queries = V2QueryCoordinator<Int>(configuration: .init(maximumFlights: 2, maximumSubscribers: 2, maximumSubscribersPerFlight: 1))
        let gate = QueryTestGate()
        let request = key()
        let first = Task { try await queries.query(request) { await gate.run() } }
        await wait { await queries.snapshot().subscribers == 1 }
        do { _ = try await queries.query(request) { 99 }; XCTFail("Expected per-flight overload") }
        catch V2QueryCoordinator<Int>.QueryError.overloaded {}
        await queries.invalidate(scope: request.scope)
        do { _ = try await first.value; XCTFail("Expected invalidation") } catch is CancellationError {}
        let old = await queries.snapshot(); XCTAssertEqual(old.flights, 1)
        let replacement = Task { try await queries.query(request) { 8 } }
        let value = try await replacement.value; XCTAssertEqual(value, 8)
        await gate.open(1)
        await queries.closeAndDrain()
    }
    func testCloseRejectsDemandAndWaitsForNonCooperativeOperation() async throws {
        let queries = V2QueryCoordinator<Int>()
        let gate = QueryTestGate()
        let request = key()
        let work = Task { try await queries.query(request) { await gate.run() } }
        await wait { await gate.calls() == 1 }
        await queries.beginClose()
        let closing = Task { await queries.closeAndDrain() }
        do { _ = try await work.value; XCTFail("Expected close") } catch V2QueryCoordinator<Int>.QueryError.closed {}
        do { _ = try await queries.query(request) { 2 }; XCTFail("Expected closed admission") }
        catch V2QueryCoordinator<Int>.QueryError.closed {}
        let state = await queries.snapshot(); XCTAssertEqual(state.flights, 1); XCTAssertTrue(state.closed)
        await gate.open(1); await closing.value
        let drained = await queries.snapshot(); XCTAssertEqual(drained.flights, 0)
    }
}
private actor QueryTestGate {
    private var continuations: [CheckedContinuation<Int, Never>] = []
    private var count = 0
    private var result: Int?
    func run() async -> Int {
        count += 1
        if let result { return result }
        return await withCheckedContinuation { continuations.append($0) }
    }
    func calls() -> Int { count }
    func open(_ value: Int) { result = value; let pending = continuations; continuations.removeAll(); for continuation in pending { continuation.resume(returning: value) } }
}
