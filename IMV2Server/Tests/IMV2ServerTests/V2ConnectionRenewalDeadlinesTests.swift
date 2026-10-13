import Foundation
@testable import IMV2ServerGateway
import Testing

struct V2ConnectionRenewalDeadlinesTests {
    @Test("deadline updates and removal retain exactly one ticket and ordered due delivery")
    func indexedDeadlines() {
        var queue = V2ConnectionRenewalDeadlines()
        let base = ContinuousClock.now
        let ids = (0..<10_000).map { _ in UUID() }
        for i in ids.indices.reversed() { queue.set(ids[i], deadline: base + .milliseconds(i)) }
        for i in stride(from: 0, to: ids.count, by: 3) { queue.set(ids[i], deadline: nil) }
        for i in stride(from: 1, to: ids.count, by: 3) { queue.set(ids[i], deadline: base + .seconds(20)) }
        #expect(queue.count == 6_666)
        // Future deadlines remain untouched when only one connection is due.
        #expect(queue.popDue(at: base + .milliseconds(1)) == nil)
        for i in stride(from: 2, to: ids.count, by: 3) {
            #expect(queue.popDue(at: base + .milliseconds(i))?.connectionID == ids[i])
            #expect(queue.popDue(at: base + .milliseconds(i)) == nil)
        }
        #expect(queue.count == 3_333)
        queue.set(ids[1], deadline: base)
        #expect(queue.count == 3_333)
        #expect(queue.popDue(at: base)?.connectionID == ids[1])
        queue.removeAll()
        #expect(queue.first == nil && queue.count == 0)
    }
}
