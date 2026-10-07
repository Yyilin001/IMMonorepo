import Foundation
import Testing
@testable import IMV2ActorRuntime

struct V2RoomTurnDeadlinesTests {
    @Test("deadline withdrawal preserves the earliest live command without stale records", arguments: [false, true])
    func withdrawal(reverse: Bool) {
        let now = ContinuousClock.now
        let ids = (0..<100).map { _ in UUID() }
        var deadlines = V2RoomTurnDeadlines()
        let order = reverse ? Array((0..<100).reversed()) : Array(0..<100)
        // Duplicate deadline values and removal from arbitrary heap positions.
        for value in order {
            deadlines.insert(id: ids[value], deadline: now + .milliseconds(value / 2))
        }
        let removed = Set((0..<100).filter { $0 % 3 != 1 })
        for value in order where removed.contains(value) { deadlines.remove(ids[value]) }
        #expect(deadlines.count == 100 - removed.count)
        var expected = (0..<100).filter { !removed.contains($0) }
        while let entry = deadlines.first {
            let minimum = expected.map { $0 / 2 }.min()
            #expect(entry.deadline == now + .milliseconds(minimum!))
            let value = ids.firstIndex(of: entry.id)!
            #expect(expected.contains(value))
            expected.removeAll { $0 == value }
            deadlines.remove(entry.id)
            deadlines.remove(entry.id) // Late duplicate cleanup is harmless.
            #expect(deadlines.count == expected.count)
        }
        #expect(expected.isEmpty)
    }
}
