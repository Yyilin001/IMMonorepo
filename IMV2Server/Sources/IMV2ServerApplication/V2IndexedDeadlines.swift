/// Exact indexed minimum heap. Updating or removing a key never leaves stale
/// timer entries; owners only inspect due keys instead of scanning live work.
package struct V2IndexedDeadlines<Key: Hashable & Sendable>: Sendable {
    private struct Node: Sendable {
        let key: Key
        var deadline: ContinuousClock.Instant
    }
    private var nodes: [Node] = []
    private var positions: [Key: Int] = [:]
    package init() {}
    package var count: Int { nodes.count }
    package var firstDeadline: ContinuousClock.Instant? { nodes.first?.deadline }
    package mutating func set(_ key: Key, at deadline: ContinuousClock.Instant) {
        if let index = positions[key] {
            let old = nodes[index].deadline
            nodes[index].deadline = deadline
            if deadline < old { up(index) } else { down(index) }
        } else {
            positions[key] = nodes.count
            nodes.append(Node(key: key, deadline: deadline))
            up(nodes.count - 1)
        }
    }
    package mutating func popDue(at now: ContinuousClock.Instant) -> Key? {
        guard let node = nodes.first, node.deadline <= now else { return nil }
        remove(node.key)
        return node.key
    }
    package mutating func remove(_ key: Key) {
        guard let index = positions[key] else { return }
        swap(index, nodes.count - 1)
        nodes.removeLast()
        positions.removeValue(forKey: key)
        if index < nodes.count {
            if index > 0 && nodes[index].deadline < nodes[(index - 1) / 2].deadline { up(index) }
            else { down(index) }
        }
    }
    package mutating func removeAll() { nodes.removeAll(); positions.removeAll() }
    private mutating func swap(_ lhs: Int, _ rhs: Int) {
        nodes.swapAt(lhs, rhs)
        positions[nodes[lhs].key] = lhs
        positions[nodes[rhs].key] = rhs
    }
    private mutating func up(_ start: Int) {
        var index = start
        while index > 0 {
            let parent = (index - 1) / 2
            guard nodes[index].deadline < nodes[parent].deadline else { break }
            swap(index, parent); index = parent
        }
    }
    private mutating func down(_ start: Int) {
        var index = start
        while index * 2 + 1 < nodes.count {
            var child = index * 2 + 1
            if child + 1 < nodes.count && nodes[child + 1].deadline < nodes[child].deadline { child += 1 }
            guard nodes[child].deadline < nodes[index].deadline else { break }
            swap(index, child); index = child
        }
    }
}
