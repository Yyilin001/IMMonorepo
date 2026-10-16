@testable import IMV2ServerApplication
import Testing

@Suite("Exact indexed deadlines")
struct V2IndexedDeadlinesTests {
    @Test("updated and removed entries never fire stale deadlines")
    func replacementAndRemoval() {
        let now = ContinuousClock.now
        var heap = V2IndexedDeadlines<Int>()
        for key in 0..<1000 { heap.set(key, at: now + .milliseconds(key)) }
        for key in stride(from: 0, to: 1000, by: 2) { heap.remove(key) }
        heap.set(1, at: now + .seconds(10))
        heap.set(999, at: now - .seconds(1))
        #expect(heap.count == 500)
        #expect(heap.popDue(at: now) == 999)
        #expect(heap.popDue(at: now + .milliseconds(2)) == nil)
        var fired: [Int] = []
        while let key = heap.popDue(at: now + .seconds(1)) { fired.append(key) }
        #expect(fired == Array(stride(from: 3, to: 999, by: 2)))
        #expect(heap.count == 1)
        #expect(heap.popDue(at: now + .seconds(10)) == 1)
        #expect(heap.firstDeadline == nil)
    }
    @Test("reusing keys and deleting arbitrary heap positions preserves the minimum")
    func reusedKeys() {
        let now = ContinuousClock.now
        var heap = V2IndexedDeadlines<Int>()
        for key in (0..<100).reversed() { heap.set(key, at: now + .seconds(key)) }
        for key in [0, 37, 99] { heap.remove(key); heap.remove(key) }
        heap.set(37, at: now)
        #expect(heap.popDue(at: now) == 37)
        heap.set(37, at: now + .seconds(2))
        #expect(heap.popDue(at: now + .seconds(1)) == 1)
        #expect(heap.count == 97)
        heap.removeAll()
        #expect(heap.count == 0)
        #expect(heap.firstDeadline == nil)
    }
}
