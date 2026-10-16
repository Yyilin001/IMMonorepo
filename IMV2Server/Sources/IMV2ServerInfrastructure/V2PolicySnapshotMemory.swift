import Foundation
import Synchronization
import IMV2ActorContracts
import IMV2ServerApplication

/// Shared by published facts, so retiring a control generation invalidates all
/// of its readers immediately. Control messages never revive expired authority.
final class V2PolicySnapshotSession: Sendable {
    let wire: V2PolicyControlSessionWire
    private struct State: Sendable {
        var deadline: ContinuousClock.Instant
        var sequence: UInt64 = 0
        var retired = false
    }
    private let state: Mutex<State>
    init(_ wire: V2PolicyControlSessionWire, now: ContinuousClock.Instant) {
        self.wire = wire
        state = Mutex(State(deadline: now + .seconds(10)))
    }
    func ready(at instant: ContinuousClock.Instant) -> Bool {
        state.withLock {
            if instant >= $0.deadline { $0.retired = true }
            return !$0.retired
        }
    }
    func advance(sequence: UInt64, at instant: ContinuousClock.Instant) throws {
        try state.withLock {
            if instant >= $0.deadline { $0.retired = true }
            guard !$0.retired else { throw V2PolicyAuthorizationLifecycleError.ownerChanged }
            if sequence > $0.sequence {
                $0.sequence = sequence
                $0.deadline = instant + .seconds(10)
            }
        }
    }
    func retire() { state.withLock { $0.retired = true } }
}

/// One bounded fact store for cold/control writers and synchronous warm reads.
/// Publication includes the exact session that authorized the baseline. The
/// control Actor alone changes facts; readers only update the LRU links.
final class V2PolicySnapshotMemory: Sendable {
    private typealias Key = V2PolicyAuthorizationScope
    private struct Entry: Sendable {
        let snapshot: V2PolicyFactsSnapshot
        let session: V2PolicySnapshotSession?
    }
    private struct State: Sendable {
        var entries: [Key: Entry] = [:]
        var order = V2IndexedFIFO<Key, Key>()
        var closed = false
    }
    private let maximumEntries: Int
    private let state = Mutex(State())
    init(maximumEntries: Int) { self.maximumEntries = maximumEntries }

    subscript(key: V2PolicyAuthorizationScope) -> V2PolicyFactsSnapshot? {
        state.withLock { $0.entries[key]?.snapshot }
    }

    func cached(scopes: [V2PolicyAuthorizationScope], at instant: ContinuousClock.Instant) throws -> [V2PolicyFactsSnapshot]? {
        try Task.checkCancellation()
        return try state.withLock { value in
            guard !value.closed else { throw V2PolicyAuthorizationLifecycleError.closed }
            guard !scopes.isEmpty, scopes.count <= 4, scopes.allSatisfy(\.isValid),
                  Set(scopes.map(\.canonical)).count == scopes.count else {
                throw V2PolicyAuthorizationLifecycleError.invalidRequest
            }
            let keys = scopes.map(\.canonical)
            // No external callbacks under this lock. Session readiness takes a
            // separate short lock; control writers release it before publication.
            guard keys.allSatisfy({ key in
                guard let entry = value.entries[key] else { return false }
                return entry.session?.ready(at: instant) ?? true
            }) else { return nil }
            return keys.map { key in
                let moved = value.order.moveToLast(key)
                precondition(moved)
                return value.entries[key]!.snapshot
            }
        }
    }

    /// Eviction precedes release bookkeeping on the control Actor. That work
    /// can retire a session or reset interests before a new fact is published.
    func evictIfNeeded(for key: V2PolicyAuthorizationScope) -> V2PolicyAuthorizationScope? {
        state.withLock {
            guard $0.entries[key] == nil, $0.entries.count >= maximumEntries,
                  let victim = $0.order.removeFirst() else { return nil }
            $0.entries.removeValue(forKey: victim)
            return victim
        }
    }
    func publish(_ snapshot: V2PolicyFactsSnapshot, session: V2PolicySnapshotSession?) {
        state.withLock {
            let key = snapshot.scope.canonical
            precondition(!$0.closed && ($0.entries[key] != nil || $0.entries.count < maximumEntries))
            $0.entries[key] = Entry(snapshot: snapshot, session: session)
            if !$0.order.moveToLast(key) { $0.order.append(key, key: key) }
        }
    }
    func rebind(_ key: V2PolicyAuthorizationScope, session: V2PolicySnapshotSession?) {
        state.withLock {
            if let old = $0.entries[key] {
                $0.entries[key] = Entry(snapshot: old.snapshot, session: session)
            }
        }
    }
    func removeValue(forKey key: V2PolicyAuthorizationScope) {
        state.withLock {
            $0.entries.removeValue(forKey: key)
            $0.order.remove(key)
        }
    }
    func close() {
        let removed = state.withLock {
            $0.closed = true
            let removed = ($0.entries, $0.order)
            $0.entries = [:]
            $0.order = .init()
            return removed
        }
        withExtendedLifetime(removed) {}
    }
}
