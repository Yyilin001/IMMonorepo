import Foundation
import Synchronization

/// Invalidations are hints to reread durable projections, never business events.
public struct V2ProjectionScopes: OptionSet, Equatable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let conversations = Self(rawValue: 1 << 0)
    public static let conversationDetails = Self(rawValue: 1 << 1)
    public static let contacts = Self(rawValue: 1 << 2)
    public static let privacy = Self(rawValue: 1 << 3)
    public static let all: Self = [.conversations, .conversationDetails, .contacts, .privacy]
}

public struct V2ProjectionChange: Equatable, Sendable {
    public let scopes: V2ProjectionScopes
    public let requiresImmediateRefresh: Bool
    public init(scopes: V2ProjectionScopes, requiresImmediateRefresh: Bool) {
        self.scopes = scopes
        self.requiresImmediateRefresh = requiresImmediateRefresh
    }
    public static let all = Self(scopes: .all, requiresImmediateRefresh: true)
    static let none = Self(scopes: [], requiresImmediateRefresh: false)

    public func merging(_ other: Self) -> Self {
        .init(scopes: scopes.union(other.scopes),
              requiresImmediateRefresh: requiresImmediateRefresh || other.requiresImmediateRefresh)
    }
}

/// One subscriber, one iterator. A buffered wake may be replaced, but its pending
/// scopes and urgency are unioned until consumed. A later ordinary update cannot
/// erase an earlier revocation while the UI is busy rendering.
public struct V2ProjectionChangeSubscription: AsyncSequence, Sendable {
    public typealias Element = V2ProjectionChange
    let identifier: UUID
    let hub: V2ProjectionChangeHub
    let wakes: AsyncStream<Void>

    public struct AsyncIterator: AsyncIteratorProtocol {
        let identifier: UUID
        let hub: V2ProjectionChangeHub
        var wakes: AsyncStream<Void>.Iterator
        public mutating func next() async -> V2ProjectionChange? {
            while await wakes.next() != nil {
                if let change = hub.take(identifier) { return change }
            }
            return nil
        }
    }
    public func makeAsyncIterator() -> AsyncIterator {
        .init(identifier: identifier, hub: hub, wakes: wakes.makeAsyncIterator())
    }
}

/// GRDB invokes the publisher on its writer queue; subscription cancellation
/// and consumption can happen on other executors. The mutex protects only tiny
/// in-memory slots and is never held across an await, yield, or database read.
final class V2ProjectionChangeHub: Sendable {
    private struct Slot {
        var pending: V2ProjectionChange
        let continuation: AsyncStream<Void>.Continuation
    }
    private struct State {
        var closed = false
        var slots: [UUID: Slot] = [:]
    }
    private let state = Mutex(State())

    func subscribe() -> V2ProjectionChangeSubscription {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuation.onTermination = { [weak self] _ in self?.remove(id) }
        let closed = state.withLock { state in
            guard !state.closed else { return true }
            state.slots[id] = .init(pending: .all, continuation: continuation)
            return false
        }
        if closed { continuation.finish() } else { continuation.yield(()) }
        return .init(identifier: id, hub: self, wakes: stream)
    }

    func publish(_ change: V2ProjectionChange) {
        guard !change.scopes.isEmpty else { return }
        let targets = state.withLock { state in
            for (id, slot) in state.slots { state.slots[id]?.pending = slot.pending.merging(change) }
            return state.slots.values.map(\.continuation)
        }
        for target in targets { target.yield(()) }
    }

    func take(_ id: UUID) -> V2ProjectionChange? {
        state.withLock { state in
            guard let slot = state.slots[id], !slot.pending.scopes.isEmpty else { return nil }
            state.slots[id]?.pending = .none
            return slot.pending
        }
    }

    private func remove(_ id: UUID) { _ = state.withLock { $0.slots.removeValue(forKey: id) } }

    func finish() {
        let targets = state.withLock { state in
            state.closed = true
            let targets = state.slots.values.map(\.continuation)
            state.slots.removeAll()
            return targets
        }
        for target in targets { target.finish() }
    }
}
