import Testing
@testable import IMV2ServerApplication

struct V2RealtimeKeyQueueTests {
    @Test func cancellationDeduplicationAndReinsertionPreserveFIFO() {
        var queue = V2RealtimeKeyQueue<Int>()
        for key in 0..<10_000 { queue.insert(key) }
        let insertedAgain = queue.insert(9)
        #expect(!insertedAgain)
        for key in stride(from: 0, to: 10_000, by: 2) { queue.remove(key) }
        #expect(queue.count == 5_000)
        for key in stride(from: 1, to: 10_000, by: 2) { #expect(queue.popFirst() == key) }
        #expect(queue.isEmpty && queue.popFirst() == nil)
        queue.insert(1); queue.insert(2); queue.remove(1); queue.insert(1)
        #expect(queue.popFirst() == 2 && queue.popFirst() == 1)
        queue.insert(3); queue.removeAll(); queue.insert(4)
        #expect(queue.count == 1 && queue.popFirst() == 4)
    }
}
