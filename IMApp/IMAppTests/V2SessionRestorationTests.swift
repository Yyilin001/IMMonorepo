import Foundation
import UIKit
import Testing
@testable import IMApp

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct V2SessionRestorationTests {
    @Test("Push callback has a shared store before any view exists and completes once")
    func delegateOwnsColdSession() async {
        let delegate = V2AppPushDelegate(makeStore: { _ in .init(startupMode: .uiTestingSignedOut) })
        #expect(delegate.wakeHandler === delegate.store)
        #expect(delegate.tokenReceiver === delegate.store)
        var results: [UIBackgroundFetchResult] = []
        await withCheckedContinuation { continuation in
            delegate.application(UIApplication.shared, didReceiveRemoteNotification: ["aps": ["content-available": 1]]) { result in
                results.append(result)
                continuation.resume()
            }
        }
        #expect(results == [.noData])
        #expect(delegate.store.route == .signedOut)
    }

    @Test("A Push deadline leaves the shared scene restore running")
    func independentDeadline() async throws {
        let restoration = V2SessionRestoration(workDuration: .seconds(5))
        let probe = RestoreProbe()
        let scene = Task { try await restoration.run { await probe.restore() } }
        try await eventually { probe.calls == 1 }
        let start = ContinuousClock.now
        await #expect(throws: V2SessionRestoration.Failure.deadlineReached) {
            try await restoration.run(until: .now.advanced(by: .milliseconds(50))) { await probe.restore() }
        }
        #expect(start.duration(to: .now) < .seconds(2))
        #expect(probe.calls == 1)
        #expect(!probe.finished)
        probe.release()
        try await scene.value
        #expect(!probe.cancelledOnExit)
    }

    @Test("Cancelling one restore waiter does not cancel another caller")
    func independentCancellation() async throws {
        let restoration = V2SessionRestoration()
        let probe = RestoreProbe()
        let cancelled = Task { try await restoration.run { await probe.restore() } }
        try await eventually { probe.calls == 1 }
        let survivor = Task { try await restoration.run { await probe.restore() } }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(!probe.finished)
        probe.release()
        try await survivor.value
        #expect(probe.calls == 1)
        #expect(!probe.cancelledOnExit)
    }

    @Test("Expired restore retains ownership until a late callback drains")
    func ownerDeadlineFencesLateCallback() async throws {
        let restoration = V2SessionRestoration(workDuration: .milliseconds(50))
        let probe = RestoreProbe()
        await #expect(throws: V2SessionRestoration.Failure.deadlineReached) {
            try await restoration.run { await probe.restore() }
        }
        #expect(!probe.finished)
        await #expect(throws: V2SessionRestoration.Failure.deadlineReached) {
            try await restoration.run { await probe.restore() }
        }
        #expect(probe.calls == 1)
        probe.release()
        try await eventually { !restoration.isRestoring }
        #expect(probe.cancelledOnExit)
        var retried = false
        try await restoration.run { retried = true }
        #expect(retried)
    }

    private func eventually(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw ProbeFailure.timedOut }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}

private enum ProbeFailure: Error { case timedOut }
@MainActor
private final class RestoreProbe {
    var calls = 0
    var finished = false
    var cancelledOnExit = false
    private var continuation: CheckedContinuation<Void, Never>?
    func restore() async {
        calls += 1
        await withCheckedContinuation { continuation = $0 }
        cancelledOnExit = Task.isCancelled
        finished = true
    }
    func release() { continuation?.resume(); continuation = nil }
}
