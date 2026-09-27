import Foundation
import Testing
@testable import IMApp

@MainActor
@Suite("Prepared account resource lifetime", .timeLimit(.minutes(1)))
struct V2AccountActivationScopeTests {
    private enum Failure: Error { case construction, cleanup }

    @Test("early return or a failed constructor cleans everything already created", arguments: [false, true])
    func failedPreparation(throwsError: Bool) async throws {
        var order: [Int] = []
        do {
            try await V2AccountActivationScope.withPrepared { activation in
                activation.onDiscard { order.append(1) }
                activation.onDiscard { order.append(2) }
                if throwsError { throw Failure.construction }
                return
            }
            #expect(!throwsError)
        } catch Failure.construction { #expect(throwsError) }
        #expect(order == [2, 1])
    }

    @Test func failedCleanupStillDrainsOtherOwners() async throws {
        var order: [Int] = []
        do {
            try await V2AccountActivationScope.withPrepared { activation in
                activation.onDiscard { order.append(1) }
                activation.onDiscard { order.append(2); throw Failure.cleanup }
                activation.onDiscard { order.append(3) }
                throw Failure.construction
            }
            Issue.record("cleanup failure was hidden")
        } catch Failure.cleanup { }
        #expect(order == [3, 2, 1])
    }

    @Test func cancellationBeforeAdoptionWaitsForCleanup() async throws {
        let gate = ActivationCleanupGate()
        var published = false, discarded = false, returned = false
        let attempt = Task {
            defer { returned = true }
            try await V2AccountActivationScope.withPrepared { activation in
                activation.onDiscard { await gate.wait(); discarded = true }
                withUnsafeCurrentTask { $0?.cancel() }
                try activation.adopt()
                published = true
            }
        }
        await gate.entered()
        #expect(!published && !discarded && !returned)
        await gate.release()
        await #expect(throws: CancellationError.self) { try await attempt.value }
        #expect(!published && discarded && returned)
    }

    @Test func successfulAdoptionHandsCleanupToTheAccountOwner() async throws {
        var discarded = false, published = false
        try await V2AccountActivationScope.withPrepared { activation in
            activation.onDiscard { discarded = true }
            try activation.adopt()
            published = true
        }
        #expect(published && !discarded)
    }
}

private actor ActivationCleanupGate {
    private let starts = AsyncStream<Void>.makeStream()
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        await withCheckedContinuation {
            continuation = $0
            starts.continuation.yield(())
        }
    }
    func entered() async { var iterator = starts.stream.makeAsyncIterator(); _ = await iterator.next() }
    func release() { continuation?.resume(); continuation = nil }
}
