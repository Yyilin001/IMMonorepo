import IMV2ServerApplication
import IMV2ServerContracts
@testable import IMV2ServerInfrastructure
import NIOCore
import NIOPosix
import Synchronization
import Testing

@Suite("Actual owner admission handoff observation")
struct V2OwnerAdmissionHandoffTraceTests {
    @Test("raw future completion precedes caller validation; only validated dispatch is counted",
          arguments: ["single", "fallback", "multi", "invalid"])
    func futureReadyIsMeasuredBeforeCallerResumes(scenario: String) async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let loop = group.next()
        let trace = V2OwnerAdmissionHandoffTrace(), metrics = V2SendOperationBatchMetrics()
        let result = loop.makePromise(of: Int.self)
        let resume = loop.makePromise(of: Void.self)
        let released = Mutex(false)
        @Sendable func releaseCaller() {
            let first = released.withLock { released in
                guard !released else { return false }
                released = true
                return true
            }
            if first { resume.succeed(()) }
        }
        let mapped = result.futureResult.map { value in
            trace.resultReady()
            return value
        }
        trace.beginQuota()
        if scenario == "fallback" {
            // A genuinely settled zero-row fast result is not successful
            // validation. The final quota future overwrites its start time.
            let zero = loop.makePromise(of: Int.self)
            let zeroMapped = zero.futureResult.map { value in trace.resultReady(); return value }
            zero.succeed(0)
            #expect(try await zeroMapped.get() == 0)
            #expect(metrics.sendOperationBatchMetricsSnapshot().ownerAdmissionHandoffs.values.allSatisfy { $0.count == 0 })
        }
        let path: V2SendOperationAdmissionPath = scenario == "fallback" ? .singleFallback :
            (scenario == "multi" ? .multiGroup : .singleSuccess)
        // The caller cannot validate or dispatch until this independent gate
        // is released, even after the underlying SQL-style future has ended.
        let caller = Task {
            try await resume.futureResult.get()
            let rows = try await mapped.get()
            if rows == 1 { trace.validated(path: path) }
            trace.willDispatchCommit(metrics: metrics)
            trace.willDispatchCommit(metrics: metrics) // Idempotent dispatch.
        }
        result.succeed(scenario == "invalid" ? -1 : 1)
        do {
            _ = try await mapped.get() // Actual future and its ready-map settled.
            let gatedFrom = ContinuousClock.now
            #expect(metrics.sendOperationBatchMetricsSnapshot().ownerAdmissionHandoffs.values.allSatisfy { $0.count == 0 })
            await Task.yield()
            let releasedAt = ContinuousClock.now
            releaseCaller()
            try await caller.value
            let snapshot = metrics.sendOperationBatchMetricsSnapshot()
            if scenario == "invalid" {
                #expect(snapshot.ownerAdmissionHandoffs.values.allSatisfy { $0.count == 0 })
            } else {
                let item = try #require(snapshot.ownerAdmissionHandoffs[path])
                #expect(item.count == 1)
                #expect(snapshot.ownerAdmissionHandoffs.values.reduce(0) { $0 + $1.count } == 1)
                let interval = gatedFrom.duration(to: releasedAt).components
                let observedGateMilliseconds = Double(interval.seconds) * 1_000 + Double(interval.attoseconds) / 1e15
                // If resultReady were sampled only on the caller's resume,
                // this already-completed-future gated interval would be lost.
                #expect(item.resultReadyToValidatedMillisecondsTotal >= observedGateMilliseconds)
                #expect(item.resultReadyToValidatedMillisecondsMax == item.resultReadyToValidatedMillisecondsTotal)
                #expect(item.validatedToCommitDispatchMillisecondsTotal >= 0)
            }
            try await group.shutdownGracefully()
        } catch {
            releaseCaller()
            _ = await caller.result
            try? await group.shutdownGracefully()
            throw error
        }
    }
}
