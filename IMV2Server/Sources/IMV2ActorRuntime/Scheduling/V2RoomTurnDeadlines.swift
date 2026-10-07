import Foundation

/// An indexed min-heap: removal does not leave stale deadline records behind.
/// One entry follows a command from queued through actual execution/holding.
struct V2RoomTurnDeadlines: Sendable {
    struct Entry: Sendable {
        let id: UUID
        let deadline: ContinuousClock.Instant
    }
    private var heap: [Entry] = []
    private var positions: [UUID: Int] = [:]
    var count: Int { heap.count }
    var first: Entry? { heap.first }

    mutating func insert(id: UUID, deadline: ContinuousClock.Instant) {
        precondition(positions[id] == nil)
        positions[id] = heap.count
        heap.append(.init(id: id, deadline: deadline))
        siftUp(heap.count - 1)
    }

    mutating func remove(_ id: UUID) {
        guard let index = positions.removeValue(forKey: id) else { return }
        let last = heap.removeLast()
        guard index < heap.count else { return }
        heap[index] = last
        positions[last.id] = index
        if index > 0, heap[index].deadline < heap[(index - 1) / 2].deadline {
            siftUp(index)
        } else { siftDown(index) }
    }

    private mutating func swap(_ a: Int, _ b: Int) {
        heap.swapAt(a, b)
        positions[heap[a].id] = a
        positions[heap[b].id] = b
    }

    private mutating func siftUp(_ start: Int) {
        var index = start
        while index > 0 {
            let parent = (index - 1) / 2
            guard heap[index].deadline < heap[parent].deadline else { break }
            swap(index, parent); index = parent
        }
    }

    private mutating func siftDown(_ start: Int) {
        var index = start
        while index * 2 + 1 < heap.count {
            let left = index * 2 + 1, right = left + 1
            let child = right < heap.count && heap[right].deadline < heap[left].deadline ? right : left
            guard heap[child].deadline < heap[index].deadline else { break }
            swap(index, child); index = child
        }
    }
}
