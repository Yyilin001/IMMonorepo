@testable import IMV2ServerInfrastructure
import Testing

@Suite("indexed room FIFO")
struct V2IndexedFIFOTests {
    @Test("cancellation at head, middle and tail preserves remaining order and reuse")
    func removalAndReuse() {
        var queue = V2IndexedFIFO<Int, Int>()
        for value in 0..<10 { queue.append(value, key: value) }
        #expect(queue.remove(4) == 4)
        #expect(queue.remove(4) == nil)
        #expect(queue.remove(0) == 0)
        #expect(queue.remove(9) == 9)
        queue.prepend(0, key: 0)
        queue.append(9, key: 9)
        #expect(queue.values == [0, 1, 2, 3, 5, 6, 7, 8, 9])
        for expected in [0, 1, 2, 3, 5, 6, 7, 8, 9] { #expect(queue.removeFirst() == expected) }
        #expect(queue.isEmpty && queue.first == nil && queue.removeFirst() == nil)
        queue.append(12, key: 12)
        #expect(queue.first == 12 && queue.count == 1)
        queue.removeAll()
        #expect(queue.values.isEmpty && queue.count == 0)
    }
}
