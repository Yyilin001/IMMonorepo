/// Actor-confined FIFO with constant-time head removal and cancellation by key.
/// Traversal borrows values without allocating a snapshot.
package struct V2IndexedFIFO<Key: Hashable & Sendable, Value: Sendable>: Sendable {
    private struct Node: Sendable {
        var value: Value
        var previous: Key?
        var next: Key?
    }
    private var nodes: [Key: Node] = [:]
    private var head: Key?
    private var tail: Key?
    package var count: Int { nodes.count }
    package var isEmpty: Bool { nodes.isEmpty }
    package var first: Value? { head.flatMap { nodes[$0]?.value } }
    /// Project a small head field without returning an owned Value to callers.
    package borrowing func firstMap<Result>(_ transform: (borrowing Value) throws -> Result) rethrows -> Result? {
        guard let head, let node = nodes[head] else { return nil }
        return try transform(node.value)
    }
    /// Visits in FIFO order without materializing a snapshot. The callback
    /// cannot mutate this queue while its read access is active.
    package borrowing func forEach(_ visit: (borrowing Value) throws -> Void) rethrows {
        var key = head
        while let current = key, let node = nodes[current] {
            try visit(node.value)
            key = node.next
        }
    }
    /// Advance before removal so expired entries can be removed in one pass.
    package mutating func removeAll(
        where predicate: (borrowing Value) -> Bool,
        onRemove: (consuming Value) -> Void
    ) {
        var key = head
        while let current = key, let node = nodes[current] {
            key = node.next
            if predicate(node.value), let removed = remove(current) {
                onRemove(removed)
            }
        }
    }
    /// Mutate records in order without retaining a copied queue snapshot.
    package mutating func updateEach(_ visit: (inout Value) -> Void) {
        var key = head
        while let current = key, var node = nodes[current] {
            key = node.next
            visit(&node.value)
            nodes[current] = consume node
        }
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
