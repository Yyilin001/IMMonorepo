@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Foundation
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
import Testing
@testable import IMV2ServerGateway

@Suite("V2 gateway inbound queue")
struct V2GatewayInboundQueueTests {
    @Test("wraps repeatedly without losing FIFO order or byte accounting")
    func preservesOrderAcrossRingWraps() {
        var queue = V2GatewayInboundQueue(maximumBytes: 4_096, maximumChunks: 64)
        var nextExpected = 0
        for value in 0..<100_000 {
            let bytes = encoded(value)
            let appended = queue.append(bytes)
            #expect(appended)
            if queue.count >= 48 {
                let removed = queue.popFirst()
                #expect(removed == encoded(nextExpected))
                nextExpected += 1
            }
        }
        while let removed = queue.popFirst() {
            #expect(removed == encoded(nextExpected))
            nextExpected += 1
        }
        #expect(nextExpected == 100_000)
        #expect(queue.queuedBytes == 0)
        #expect(queue.isEmpty)
    }

    @Test("rejects either byte or chunk overflow without mutating admitted state")
    func enforcesBothBounds() {
        var queue = V2GatewayInboundQueue(maximumBytes: 4, maximumChunks: 2)
        let oversizedAppend = queue.append(Data(repeating: 0, count: 5))
        #expect(!oversizedAppend)
        let firstAppend = queue.append(Data([1, 2]))
        #expect(firstAppend)
        let secondAppend = queue.append(Data([3, 4]))
        #expect(secondAppend)
        let excessChunkAppend = queue.append(Data())
        #expect(!excessChunkAppend)
        #expect(queue.count == 2)
        #expect(queue.queuedBytes == 4)
        let first = queue.popFirst()
        #expect(first == Data([1, 2]))
        #expect(queue.queuedBytes == 2)
        queue.removeAll()
        #expect(queue.count == 0)
        #expect(queue.queuedBytes == 0)
    }

    private func encoded(_ value: Int) -> Data {
        withUnsafeBytes(of: UInt64(value).bigEndian) { Data($0) }
    }
}
