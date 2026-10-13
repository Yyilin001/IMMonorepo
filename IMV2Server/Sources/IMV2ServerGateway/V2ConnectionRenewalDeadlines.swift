import Foundation

/// Indexed minimum heap: one deadline per connection, no stale tickets or full scans.
/// The connection lease controller owns all access.
struct V2ConnectionRenewalDeadlines {
    struct Entry {
        let connectionID: UUID
        var deadline: ContinuousClock.Instant
    }
    private var entries: [Entry] = []
    private var positions: [UUID: Int] = [:]
    var first: Entry? { entries.first }
    var count: Int { entries.count }

    mutating func set(_ id: UUID, deadline: ContinuousClock.Instant?) {
        guard let deadline else { remove(id); return }
        if let index = positions[id] {
            let old = entries[index].deadline
            entries[index].deadline = deadline
            if deadline < old { siftUp(index) } else { siftDown(index) }
        } else {
            positions[id] = entries.count
            entries.append(.init(connectionID: id, deadline: deadline))
            siftUp(entries.count - 1)
        }
    }

    @discardableResult
    mutating func popDue(at now: ContinuousClock.Instant) -> Entry? {
        guard let first, first.deadline <= now else { return nil }
        remove(first.connectionID)
        return first
    }

    mutating func removeAll() {
        entries.removeAll()
        positions.removeAll()
    }

    private mutating func remove(_ id: UUID) {
        guard let index = positions.removeValue(forKey: id) else { return }
        let last = entries.removeLast()
        guard index < entries.count else { return }
        entries[index] = last
        positions[last.connectionID] = index
        if index > 0, entries[index].deadline < entries[(index - 1) / 2].deadline {
            siftUp(index)
        } else { siftDown(index) }
    }

    private mutating func swap(_ a: Int, _ b: Int) {
        entries.swapAt(a, b)
        positions[entries[a].connectionID] = a
        positions[entries[b].connectionID] = b
    }

    private mutating func siftUp(_ position: Int) {
        var index = position
        while index > 0 {
            let parent = (index - 1) / 2
            guard entries[index].deadline < entries[parent].deadline else { break }
            swap(index, parent)
            index = parent
        }
    }

    private mutating func siftDown(_ position: Int) {
        var index = position
        while index * 2 + 1 < entries.count {
            let left = index * 2 + 1, right = left + 1
            let next = right < entries.count && entries[right].deadline < entries[left].deadline ? right : left
            guard entries[next].deadline < entries[index].deadline else { break }
            swap(index, next)
            index = next
        }
    }
}
