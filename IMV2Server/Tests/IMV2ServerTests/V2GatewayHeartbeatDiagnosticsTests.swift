import NIOCore
import Testing
import IMV2ServerApplication
@testable import IMV2ServerGateway

@Suite("Gateway heartbeat diagnostics")
struct V2GatewayHeartbeatDiagnosticsTests {
    @Test("process-prefixed connection UUIDs do not select an entire node or no connections")
    func processPrefixedIdentifiers() {
        let ids = (0..<8_192).map { _ in V2SecureProcessUUIDGenerator.shared.makeOne() }
        #expect(Set(ids.map { $0.uuid.0 }).count == 1)
        let selected = ids.filter(V2GatewayHeartbeatDiagnostics.selects)
        #expect(!selected.isEmpty && selected.count < ids.count)
        #expect(selected.allSatisfy(V2GatewayHeartbeatDiagnostics.selects))
    }
    @Test("completed spans partition the same request and keep sub-millisecond precision")
    func correlatedStages() {
        let metrics = V2GatewayHeartbeatDiagnostics.Metrics()
        let probe = V2GatewayHeartbeatProbe(chunkReceivedAt: 1_000, metrics: metrics)
        for point in V2GatewayHeartbeatDiagnostics.Point.allCases.dropFirst() {
            probe.mark(point, at: 1_000 + UInt64(point.rawValue) * 100_000)
        }
        probe.finish(success: true)
        probe.finish(success: false) // Task cleanup must not count this twice.
        let result = metrics.snapshot()
        #expect(result.completed == 1)
        #expect(result.failed == 0)
        #expect(result.all[.serverTotal]?.sumNanoseconds == 2_200_000)
        #expect(result.all[.leaseEntry]?.sumNanoseconds == 100_000)
        #expect(result.all.filter { $0.key != .serverTotal }.values.reduce(0) { $0 + $1.sumNanoseconds } == 2_200_000)
        #expect(result.slow.isEmpty)
        #expect(V2GatewayHeartbeatDiagnostics.render(result).contains("stage=\"lease_entry\",cohort=\"all\"} 0.1"))
    }

    @Test("failures are excluded and slow examples retain only the largest 16")
    func boundedSlowExamples() {
        let metrics = V2GatewayHeartbeatDiagnostics.Metrics()
        for milliseconds in 25...50 {
            let probe = V2GatewayHeartbeatProbe(chunkReceivedAt: 0, metrics: metrics)
            probe.mark(.writeCompleted, at: UInt64(milliseconds) * 1_000_000)
            probe.finish(success: true)
        }
        let failed = V2GatewayHeartbeatProbe(chunkReceivedAt: 0, metrics: metrics)
        failed.finish(success: false)
        failed.finish(success: false)
        let result = metrics.snapshot()
        #expect(result.completed == 26)
        #expect(result.failed == 1)
        #expect(result.slow[.serverTotal]?.count == 26)
        #expect(result.slowExamples.count == 16)
        #expect(result.slowExamples.first?.stages[.serverTotal] == 50_000_000)
        #expect(result.slowExamples.last?.stages[.serverTotal] == 35_000_000)
    }

    @Test("inbound receipt times stay paired with their bounded queued chunks")
    func queuedReceiptTimes() {
        var queue = V2GatewayInboundQueue(maximumBytes: 10, maximumChunks: 2)
        let bytes = ByteBuffer(bytes: [1, 2, 3])
        let first = queue.append(bytes, observedAt: 100)
        let second = queue.append(bytes, observedAt: 200)
        let overflow = queue.append(bytes, observedAt: 300)
        let firstReceipt = queue.popFirstObserved()?.observedAt
        let secondReceipt = queue.popFirstObserved()?.observedAt
        #expect(first && second && !overflow)
        #expect(firstReceipt == 100)
        #expect(secondReceipt == 200)
        #expect(queue.queuedBytes == 0)
    }
}
