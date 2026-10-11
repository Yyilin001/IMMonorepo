/// FIFO cache for immutable result identities. Updating an existing value does
/// not refresh its insertion order. Full-cache eviction touches one ring slot.
package struct V2BoundedInsertionCache<Key: Hashable & Sendable, Value: Sendable>: Sendable {
    private var values: [Key: Value] = [:]
    private var ring: [Key?]
    private var next = 0
    package var count: Int { values.count }

    package init(capacity: Int) {
        precondition(capacity > 0)
        ring = [Key?](repeating: nil, count: capacity)
        values.reserveCapacity(capacity)
    }
    package borrowing func value(for key: Key) -> Value? { values[key] }
    package mutating func insert(_ value: consuming Value, for key: Key) {
        if values[key] == nil {
            if let oldest = ring[next] { values.removeValue(forKey: oldest) }
            ring[next] = key
            next += 1
            if next == ring.count { next = 0 }
        }
        values[key] = consume value
    }
}
