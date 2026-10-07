import Foundation
import Synchronization
import Testing
@testable import IMV2ActorContracts

@Suite(.serialized)
struct V2SendPathTraceTests {
    @Test("handoff boundaries remain zero-duration points after queue normalization")
    func handoffBoundaries() throws {
        let snapshots = Mutex<[V2SendPathTrace.Snapshot]>([])
        let operation = UUID().uuidString
        V2SendPathTrace.installSink { value in
            if value.operations == [operation] { snapshots.withLock { $0.append(value) } }
        }
        defer { V2SendPathTrace.installSink(nil) }
        let trace = V2SendPathTrace(operations: [operation], segment: "room_actor")
        trace.record("room_queue_wait", from: .now - .milliseconds(100))
        trace.mark("dispatch")
        trace.mark("entered")
        trace.finish()
        let value = try #require(snapshots.withLock { $0.first })
        let dispatch = try #require(value.spans.first { $0.stage == "dispatch" })
        let entered = try #require(value.spans.first { $0.stage == "entered" })
        #expect(dispatch.durationMilliseconds == 0 && entered.durationMilliseconds == 0)
        #expect(dispatch.startMilliseconds >= 100)
        #expect(entered.startMilliseconds >= dispatch.startMilliseconds)
    }
    @Test("repeated sink delivery remains safe in optimized builds")
    func repeatedSinkDelivery() {
        let count = Mutex(0)
        V2SendPathTrace.installSink { _ in count.withLock { $0 += 1 } }
        defer { V2SendPathTrace.installSink(nil) }
        for _ in 0..<20_000 {
            V2SendPathTrace(operations: [], segment: "gateway").finish()
        }
        #expect(count.withLock { $0 } == 20_000)
    }
    @Test("diagnostic spans are bounded and a trace finishes exactly once")
    func boundedCompletion() throws {
        let snapshots = Mutex<[V2SendPathTrace.Snapshot]>([])
        let operation = UUID().uuidString
        V2SendPathTrace.installSink { value in
            if value.operations == [operation] { snapshots.withLock { $0.append(value) } }
        }
        defer { V2SendPathTrace.installSink(nil) }
        let trace = V2SendPathTrace(operations: [], segment: "gateway")
        trace.setOperation(operation)
        let start = ContinuousClock.now - .milliseconds(200)
        for _ in 0..<256 { trace.record("test", from: start) }
        trace.finish(); trace.finish()
        trace.record("late", from: start)
        let observed = snapshots.withLock { $0 }
        #expect(observed.count == 1)
        let value = try #require(observed.first)
        #expect(value.operations == [operation])
        #expect(value.spans.count == 128)
        #expect(value.spans.allSatisfy { $0.durationMilliseconds >= 0 })
        #expect(value.durationMilliseconds >= 200)
        #expect(value.spans.first?.startMilliseconds == 0)
    }
}
