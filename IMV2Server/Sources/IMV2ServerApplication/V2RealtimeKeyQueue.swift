// One retained node per key. Removal does not leave stale FIFO tickets.
// Owned by the containing actor; all operations are expected O(1).
package struct V2RealtimeKeyQueue<Key: Hashable & Sendable>: Sendable {
    private struct Node: Sendable { var previous: Key?; var next: Key? }
    private var nodes: [Key: Node] = [:]
    private var first: Key?
    private var last: Key?
    package init() {}
    package var isEmpty: Bool { nodes.isEmpty }
    package var count: Int { nodes.count }
    @discardableResult package mutating func insert(_ key: Key) -> Bool {
        guard nodes[key] == nil else { return false }
        nodes[key] = Node(previous: last, next: nil)
        if let last { nodes[last]?.next = key } else { first = key }
        last = key; return true
    }
    @discardableResult package mutating func remove(_ key: Key) -> Key? {
        guard let node = nodes.removeValue(forKey: key) else { return nil }
        if let previous = node.previous { nodes[previous]?.next = node.next } else { first = node.next }
        if let next = node.next { nodes[next]?.previous = node.previous } else { last = node.previous }
        return key
    }
    package mutating func popFirst() -> Key? { first.flatMap { remove($0) } }
    package mutating func formUnion(_ keys: some Sequence<Key>) { for key in keys { insert(key) } }
    package mutating func removeAll() { nodes.removeAll(); first = nil; last = nil }
}
