/// Actor-confined FIFO with constant-time head removal and cancellation by key.
/// Values are copied only for deadline expiry / shutdown traversal.
package struct V2IndexedFIFO<Key: Hashable & Sendable, Value: Sendable>: Sendable {
    private struct Node: Sendable {
        let value: Value
        var previous: Key?
        var next: Key?
    }
    private var nodes: [Key: Node] = [:]
    private var head: Key?
    private var tail: Key?
    package var count: Int { nodes.count }
    package var isEmpty: Bool { nodes.isEmpty }
    package var first: Value? { head.flatMap { nodes[$0]?.value } }
    package var values: [Value] {
        var result: [Value] = []
        var key = head
        while let current = key, let node = nodes[current] {
            result.append(node.value)
            key = node.next
        }
        return result
    }
    package mutating func append(_ value: Value, key: Key) {
        precondition(nodes[key] == nil)
        nodes[key] = Node(value: value, previous: tail, next: nil)
        if let tail { nodes[tail]?.next = key } else { head = key }
        tail = key
    }
    package mutating func update(_ value: Value, key: Key) {
        guard var node = nodes[key] else { return }
        node = Node(value: value, previous: node.previous, next: node.next)
        nodes[key] = node
    }
    package mutating func prepend(_ value: Value, key: Key) {
        precondition(nodes[key] == nil)
        nodes[key] = Node(value: value, previous: nil, next: head)
        if let head { nodes[head]?.previous = key } else { tail = key }
        head = key
    }
    @discardableResult
    package mutating func remove(_ key: Key) -> Value? {
        guard let node = nodes.removeValue(forKey: key) else { return nil }
        if let previous = node.previous { nodes[previous]?.next = node.next } else { head = node.next }
        if let next = node.next { nodes[next]?.previous = node.previous } else { tail = node.previous }
        return node.value
    }
    @discardableResult
    package mutating func removeFirst() -> Value? {
        guard let head else { return nil }
        return remove(head)
    }
    package mutating func removeAll() { nodes.removeAll(); head = nil; tail = nil }
}
