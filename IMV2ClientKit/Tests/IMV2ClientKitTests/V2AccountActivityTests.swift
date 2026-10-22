import XCTest
import Synchronization
@testable import IMV2ClientKit

final class V2AccountActivityTests: XCTestCase, @unchecked Sendable {
    private enum Failure: Error { case unavailable }

    func testFailureIsObservableWithoutCallbackAndCloseFinishesStream() async throws {
        let runtime = V2AccountRuntime()
        let updates = try await runtime.activityUpdates()
        var iterator = updates.makeAsyncIterator()
        let initial = await iterator.next()
        XCTAssertEqual(initial, [:])
        await runtime.startActivity(id: "commands") { throw Failure.unavailable }
        for _ in 0..<10_000 {
            if await runtime.activitySnapshot()["commands"] == .failed { break }
            await Task.yield()
        }
        let snapshot = await runtime.activitySnapshot()
        XCTAssertEqual(snapshot["commands"], .failed)
        let observed = await iterator.next()
        XCTAssertEqual(observed?["commands"], .failed)
        await runtime.close()
        let closed = await iterator.next()
        XCTAssertEqual(closed?["commands"], .cancelled)
        let end = await iterator.next()
        XCTAssertNil(end)
    }

    func testReplacedNonCooperativeFailureCannotOverwriteSuccessor() async throws {
        let runtime = V2AccountRuntime()
        let old = ActivityGate()
        let current = ActivityGate()
        let callbacks = Mutex(0)
        await runtime.startActivity(id: "commands", operation: {
            await old.wait()
            throw Failure.unavailable
        }, onFailure: { _ in callbacks.withLock { $0 += 1 } })
        await old.waitUntilEntered()
        let replace = Task {
            await runtime.startActivity(id: "commands") { await current.wait() }
        }
        for _ in 0..<10_000 {
            if await runtime.activitySnapshot()["commands"] == .starting { break }
            await Task.yield()
        }
        await old.open()
        await replace.value
        await current.waitUntilEntered()
        let running = await runtime.activitySnapshot()
        XCTAssertEqual(running["commands"], .running)
        XCTAssertEqual(callbacks.withLock { $0 }, 0)
        await current.open()
        await runtime.close()
    }

    func testObserversAreBoundedButAllAccountActivitiesStart() async throws {
        let runtime = V2AccountRuntime()
        var streams: [AsyncStream<[String: V2AccountRuntime.ActivityState]>] = []
        for _ in 0..<8 { streams.append(try await runtime.activityUpdates()) }
        do { _ = try await runtime.activityUpdates(); XCTFail("Expected observer limit") }
        catch V2AccountRuntime.ObservationError.tooManyObservers {}
        for index in 0..<24 { await runtime.startActivity(id: "activity-\(index)") {} }
        let state = await runtime.activitySnapshot()
        XCTAssertEqual(state.count, 24)
        XCTAssertNotNil(state["activity-23"])
        await runtime.close()
        XCTAssertEqual(streams.count, 8)
    }
}

private actor ActivityGate {
    private var entered = false
    private var opened = false
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async {
        entered = true
        if opened { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func waitUntilEntered() async { while !entered { await Task.yield() } }
    func open() { opened = true; waiter?.resume(); waiter = nil }
}
