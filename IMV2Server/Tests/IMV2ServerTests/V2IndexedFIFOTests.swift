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
        var visited: [Int] = []
        queue.forEach { visited.append($0) }
        #expect(visited == [0, 1, 2, 3, 5, 6, 7, 8, 9])
        for expected in [0, 1, 2, 3, 5, 6, 7, 8, 9] { #expect(queue.removeFirst() == expected) }
        #expect(queue.isEmpty && queue.first == nil && queue.removeFirst() == nil)
        queue.append(12, key: 12)
        #expect(queue.first == 12 && queue.count == 1)
        #expect(queue.firstMap { $0 * 2 } == 24)
        queue.removeAll()
        #expect(queue.isEmpty && queue.count == 0)
        #expect(queue.firstMap { $0 * 2 } == nil)
    }
    @Test("expiry and in-place updates preserve order and permit key reuse")
    func borrowedTraversalAndExpiry() {
        var queue = V2IndexedFIFO<Int, Int>()
        for value in 0..<8 { queue.append(value, key: value) }
        queue.updateEach { $0 *= 10 }
        var removed: [Int] = []
        queue.removeAll(where: { $0 % 20 == 0 }, onRemove: { removed.append($0) })
        #expect(removed == [0, 20, 40, 60])
        var remaining: [Int] = []
        queue.forEach { remaining.append($0) }
        #expect(remaining == [10, 30, 50, 70])
        queue.prepend(99, key: 0)
        #expect(queue.removeFirst() == 99)
        queue.removeAll(where: { _ in true }, onRemove: { _ in })
        #expect(queue.isEmpty && queue.first == nil)
        queue.append(123, key: 0)
        #expect(queue.removeFirst() == 123)
    }

    @Test("LRU moves preserve values, head/tail links and copied queue independence")
    func moveToLast() {
        var queue = V2IndexedFIFO<Int, String>()
        for key in 0..<4 { queue.append("v\(key)", key: key) }
        let original = queue
        #expect(queue.moveToLast(99) == false)
        #expect(queue.moveToLast(3) == true)
        #expect(queue.moveToLast(0) == true)
        #expect(queue.moveToLast(2) == true)
        var values: [String] = []
        queue.forEach { values.append($0) }
        #expect(values == ["v1", "v3", "v0", "v2"])
        #expect(queue.count == 4)
        #expect(original.first == "v0")
        #expect(queue.remove(3) == "v3")
        #expect(queue.removeFirst() == "v1")
        #expect(queue.moveToLast(0) == true)
        #expect(queue.removeFirst() == "v2")
        #expect(queue.moveToLast(0) == true)
        #expect(queue.removeFirst() == "v0")
        #expect(queue.moveToLast(0) == false)
    }

}
