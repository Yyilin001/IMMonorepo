import IMV2ServerApplication
import IMV2ServerContracts
@testable import IMV2ServerInfrastructure
import NIOCore
import NIOPosix
import Synchronization
import Testing

@Suite("Actual room SQL continuation observation")
struct V2RoomSQLContinuationTraceTests {
    @Test("future settlement precedes gated Swift resumption and preserves original failures",
          arguments: ["success", "failure", "no-next"])
    func actualSettlementAndNextDispatch(scenario: String) async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let loop = group.next(), metrics = V2SendOperationBatchMetrics()
        let trace = V2RoomSQLContinuationTrace(metrics: metrics)
        let result = loop.makePromise(of: Int.self), resume = loop.makePromise(of: Void.self)
        let original = ContinuationProbeError()
        let resultSettled = Mutex(false)
        @Sendable func settleResult(_ value: Result<Int, any Error>) {
            if resultSettled.withLock({ resolved in if resolved { return false }; resolved = true; return true }) {
                result.completeWith(value)
            }
        }
        let released = Mutex(false)
        @Sendable func releaseCaller() {
            if released.withLock({ value in if value { return false }; value = true; return true }) {
                resume.succeed(())
            }
        }
        let observed = trace.track(result.futureResult, source: .scalarFenceRooms)
        let caller = Task { () -> Result<Int, any Error> in
            do {
                try await resume.futureResult.get()
                return .success(try await observed.get())
            } catch { return .failure(error) }
        }
        do {
            // A cancelled waiting caller must not manufacture actual settlement.
            if scenario == "failure" { caller.cancel() }
            var item = try #require(metrics.sendOperationBatchMetricsSnapshot().sqlContinuations[.scalarFenceRooms])
            #expect(item.settledNotResumed == 0)
            #expect(item.settledToResumedCount == 0)
            if scenario == "failure" { settleResult(.failure(original)) } else { settleResult(.success(7)) }
            // Await the wrapped actual future without permitting caller resumption.
            do { _ = try await observed.future.get() }
            catch { #expect((error as? ContinuationProbeError) === original) }
            item = try #require(metrics.sendOperationBatchMetricsSnapshot().sqlContinuations[.scalarFenceRooms])
            #expect(item.settledNotResumed == 1)
            #expect(item.resumedNotDispatched == 0)
            trace.finishWithoutDispatch() // Cannot consume an unresumed result.
            #expect(metrics.sendOperationBatchMetricsSnapshot().sqlContinuations[.scalarFenceRooms]?.settledNotResumed == 1)
            let gatedFrom = ContinuousClock.now
            await Task.yield()
            let releasedAt = ContinuousClock.now
            releaseCaller()
            let outcome = await caller.value
            switch outcome {
            case .success(let value): #expect(scenario != "failure" && value == 7)
            case .failure(let error): #expect(scenario == "failure" && (error as? ContinuationProbeError) === original)
            }
            item = try #require(metrics.sendOperationBatchMetricsSnapshot().sqlContinuations[.scalarFenceRooms])
            #expect(item.settledNotResumed == 0 && item.resumedNotDispatched == 1)
            #expect(item.settledToResumedCount == 1)
            let interval = gatedFrom.duration(to: releasedAt).components
            let gateMilliseconds = Double(interval.seconds) * 1_000 + Double(interval.attoseconds) / 1e15
            #expect(item.settledToResumedTotalMilliseconds >= gateMilliseconds)
            #expect(item.settledToResumedMaxMilliseconds == item.settledToResumedTotalMilliseconds)
            if scenario == "no-next" { trace.finishWithoutDispatch(); trace.finishWithoutDispatch() }
            else { trace.willDispatch(); trace.willDispatch() }
            trace.finishWithoutDispatch()
            trace.willDispatch() // Closed sequences never span later unobserved SQL.
            item = try #require(metrics.sendOperationBatchMetricsSnapshot().sqlContinuations[.scalarFenceRooms])
            #expect(item.resumedNotDispatched == 0)
            #expect(item.resumedToDispatchCount == (scenario == "no-next" ? 0 : 1))
            #expect(item.noNextDispatch == (scenario == "no-next" ? 1 : 0))
            if scenario == "no-next" {
                #expect(item.resumedToDispatchTotalMilliseconds == 0)
                #expect(item.resumedToDispatchMaxMilliseconds == 0)
            }
            try await group.shutdownGracefully()
        } catch {
            settleResult(.failure(original))
            releaseCaller()
            _ = await caller.value
            try? await group.shutdownGracefully()
            throw error
        }
    }
}

private final class ContinuationProbeError: Error, Sendable {}
