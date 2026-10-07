import Synchronization
import IMV2ActorContracts

/// Physical references share the original node cache bound. Pins protect reservations;
/// in-flight calls retain their own snapshots independently of ordinary LRU eviction.
final class V2RoomClusterReferenceCache: Sendable {
    private struct State: Sendable {
        var actors: [V2RoomActivationToken: V2RoomClusterActor] = [:]
        var previous: [V2RoomActivationToken: V2RoomActivationToken] = [:]
        var next: [V2RoomActivationToken: V2RoomActivationToken] = [:]
        var head: V2RoomActivationToken?
        var tail: V2RoomActivationToken?
        mutating func removeOrder(_ token: V2RoomActivationToken) {
            let before = previous.removeValue(forKey: token), after = next.removeValue(forKey: token)
            if let before { next[before] = after } else if head == token { head = after }
            if let after { previous[after] = before } else if tail == token { tail = before }
        }
        mutating func appendOrder(_ token: V2RoomActivationToken) {
            removeOrder(token)
            if let last = tail { next[last] = token; previous[token] = last }
            else { head = token }
            tail = token
        }
        mutating func popOrder() -> V2RoomActivationToken? {
            guard let token = head else { return nil }; removeOrder(token); return token
        }
        var pins: [V2RoomActivationToken: Int] = [:]
        var evictions: [V2ActorHostID: Set<V2RoomActivationToken>] = [:]
    }
    private let capacity: Int
    private let state = Mutex(State())
    init(capacity: Int) { self.capacity = capacity }
    func actor(for token: V2RoomActivationToken) -> V2RoomClusterActor? { state.withLock { $0.actors[token] } }
    func count(on id: V2ActorHostID) -> Int { state.withLock { $0.actors.keys.filter { $0.host.hostID == id }.count } }
    func tokens(on id: V2ActorHostID) -> [V2RoomActivationToken] { state.withLock { $0.actors.keys.filter { $0.host.hostID == id } } }
    func takeEvictions(on id: V2ActorHostID) -> Set<V2RoomActivationToken> {
        state.withLock { $0.evictions.removeValue(forKey: id) ?? [] }
    }
    func pin(_ token: V2RoomActivationToken) { state.withLock { $0.pins[token, default: 0] += 1 } }
    func unpin(_ token: V2RoomActivationToken) {
        state.withLock {
            let remaining = $0.pins[token, default: 0] - 1
            if remaining <= 0 { $0.pins[token] = nil } else { $0.pins[token] = remaining }
        }
    }
    func remove(_ token: V2RoomActivationToken) {
        state.withLock { $0.actors[token] = nil; $0.removeOrder(token) }
    }
    func removeAll(on id: V2ActorHostID) {
        state.withLock {
            for token in $0.actors.keys.filter({ $0.host.hostID == id }) {
                $0.actors[token] = nil; $0.removeOrder(token)
            }
            $0.evictions[id] = nil
            $0.pins = $0.pins.filter { $0.key.host.hostID != id }
        }
    }
    func install(_ actor: V2RoomClusterActor, for token: V2RoomActivationToken) throws -> V2RoomActivationToken? {
        try state.withLock { value in
            var evicted: V2RoomActivationToken?
            if value.actors[token] == nil, value.actors.count >= capacity {
                // Scan at most capacity entries; no asynchronous work while holding the lock.
                for _ in 0..<value.actors.count {
                    guard let candidate = value.popOrder() else { break }
                    if value.pins[candidate, default: 0] == 0 {
                        value.actors[candidate] = nil
                        value.evictions[candidate.host.hostID, default: []].insert(candidate)
                        evicted = candidate; break
                    }
                    value.appendOrder(candidate)
                }
                guard evicted != nil else { throw V2RoomCallFailure.notAccepted(.overloaded) }
            }
            value.actors[token] = actor
            value.appendOrder(token)
            return evicted
        }
    }
}
