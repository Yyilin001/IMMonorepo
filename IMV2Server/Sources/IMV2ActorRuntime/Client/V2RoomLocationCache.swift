/// A room has one value node, including its eviction-order links. Reads do not
/// change order; successful remember operations move the exact room to the tail.
/// Dictionary lookup and unlink/append perform amortized constant work without
/// scanning the cache or retaining stale order entries.
struct V2RoomLocationCache<Key: Hashable & Sendable, Value: Sendable>: Sendable {
    private struct Node: Sendable {
        var value: Value
        var previous: Key?
        var next: Key?
    }
    private let maximumCount: Int
    private var nodes: [Key: Node] = [:]
    private var oldest: Key?
    private var newest: Key?

    init(maximumCount: Int) {
        precondition(maximumCount > 0)
        self.maximumCount = maximumCount
    }

    var count: Int { nodes.count }
    subscript(key: Key) -> Value? { nodes[key]?.value }

    mutating func remember(_ value: Value, for key: Key) {
        if nodes[key] != nil {
            unlink(key)
            nodes[key]!.value = value
        } else {
            nodes[key] = Node(value: value, previous: nil, next: nil)
        }
        nodes[key]!.previous = newest
        nodes[key]!.next = nil
        if let newest { nodes[newest]!.next = key } else { oldest = key }
        newest = key
        if nodes.count > maximumCount, let oldest {
            removeValue(forKey: oldest)
        }
    }

    @discardableResult
    mutating func removeValue(forKey key: Key) -> Value? {
        guard let node = nodes[key] else { return nil }
        unlink(key)
        nodes.removeValue(forKey: key)
        return node.value
    }

    mutating func removeAll() {
        nodes.removeAll()
        oldest = nil; newest = nil
    }

    private mutating func unlink(_ key: Key) {
        guard let node = nodes[key] else { return }
        if let previous = node.previous { nodes[previous]!.next = node.next } else { oldest = node.next }
        if let next = node.next { nodes[next]!.previous = node.previous } else { newest = node.previous }
        nodes[key]!.previous = nil; nodes[key]!.next = nil
    }
}
