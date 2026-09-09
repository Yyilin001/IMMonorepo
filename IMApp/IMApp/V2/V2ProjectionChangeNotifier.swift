import Foundation
import IMV2ClientKit

/// Page-scoped invalidations. Ordinary commits share a 150ms window; safety
/// changes flush the pending union immediately. Timers and the SQLite reader
/// belong to the current set of subscribers and cannot outlive it.
actor V2ProjectionChangeNotifier {
    struct Request: Equatable, Sendable {
        let generation: UInt64
        let requiresImmediateRefresh: Bool
    }
    struct Subscription: AsyncSequence, Sendable {
        typealias Element = Request
        let id: UUID
        let notifier: V2ProjectionChangeNotifier
        let wakes: AsyncStream<Void>
        struct AsyncIterator: AsyncIteratorProtocol {
            let id: UUID
            let notifier: V2ProjectionChangeNotifier
            var wakes: AsyncStream<Void>.Iterator
            mutating func next() async -> Request? { await next(isolation: #isolation) }
            mutating func next(isolation actor: isolated (any Actor)?) async -> Request? {
                while await wakes.next(isolation: actor) != nil {
                    if let request = await notifier.take(id) { return request }
                }
                return nil
            }
        }
        func makeAsyncIterator() -> AsyncIterator { .init(id: id, notifier: notifier, wakes: wakes.makeAsyncIterator()) }
    }
    private struct Subscriber {
        let scopes: V2ProjectionScopes
        let continuation: AsyncStream<Void>.Continuation
        var pending: Request?
    }
    private let localStore: GRDBV2LocalSyncStore?
    private let sleep: @Sendable (Duration) async throws -> Void
    private var generation: UInt64 = 0
    private var subscribers: [UUID: Subscriber] = [:]
    private var pending: V2ProjectionScopes = []
    private var timer: (id: UUID, task: Task<Void, Never>)?
    private var observer: (id: UUID, task: Task<Void, Never>)?
    private var closed = false

    init(localStore: GRDBV2LocalSyncStore? = nil,
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.localStore = localStore
        self.sleep = sleep
    }

    deinit { observer?.task.cancel(); timer?.task.cancel() }

    func updates(scopes: V2ProjectionScopes = .all) -> Subscription {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let subscription = Subscription(id: id, notifier: self, wakes: stream)
        guard !closed else { continuation.finish(); return subscription }
        subscribers[id] = .init(scopes: scopes, continuation: continuation, pending: nil)
        continuation.onTermination = { [weak self] _ in Task { await self?.remove(id) } }
        // First SQLite subscription is initialized by the atomic hub snapshot.
        if localStore == nil || observer != nil {
            subscribers[id]?.pending = .init(generation: generation, requiresImmediateRefresh: true)
            continuation.yield(())
        }
        startObservingIfNeeded()
        return subscription
    }

    private func take(_ id: UUID) -> Request? {
        let request = subscribers[id]?.pending
        subscribers[id]?.pending = nil
        return request
    }

    /// Also supports an explicit owner invalidation; unknown changes default
    /// to a full immediate refresh, never to the delayed path.
    func publish(_ change: V2ProjectionChange = .all) {
        guard !closed, !change.scopes.isEmpty else { return }
        pending.formUnion(change.scopes)
        if change.requiresImmediateRefresh {
            cancelTimer()
            flush(requiresImmediateRefresh: true)
        } else if timer == nil, !subscribers.isEmpty {
            let id = UUID(), sleep = sleep
            timer = (id, Task { [weak self] in
                do { try await sleep(.milliseconds(150)) } catch { return }
                guard !Task.isCancelled else { return }
                await self?.timerFired(id)
            })
        }
    }

    func finish() {
        closed = true
        observer?.task.cancel(); observer = nil
        cancelTimer(); pending = []
        let continuations = subscribers.values.map(\.continuation)
        subscribers.removeAll()
        for continuation in continuations { continuation.finish() }
    }

    private func startObservingIfNeeded() {
        guard observer == nil, let localStore else { return }
        let id = UUID()
        observer = (id, Task { [weak self] in
            for await change in await localStore.projectionChanges() {
                guard !Task.isCancelled else { return }
                await self?.receive(change, observerID: id)
            }
            await self?.sourceFinished(id)
        })
    }

    private func receive(_ change: V2ProjectionChange, observerID: UUID) {
        guard observer?.id == observerID else { return }
        publish(change)
    }

    private func sourceFinished(_ id: UUID) {
        guard observer?.id == id else { return }
        finish()
    }

    private func timerFired(_ id: UUID) {
        guard timer?.id == id else { return }
        timer = nil
        flush(requiresImmediateRefresh: false)
    }

    private func flush(requiresImmediateRefresh: Bool) {
        guard !pending.isEmpty else { return }
        let scopes = pending
        pending = []
        generation &+= 1
        for (id, subscriber) in subscribers where !subscriber.scopes.intersection(scopes).isEmpty {
            // A busy consumer may receive an ordinary update after an urgent
            // one. Replacing its wake must not downgrade pending urgency.
            subscribers[id]?.pending = .init(generation: generation,
                requiresImmediateRefresh: requiresImmediateRefresh || subscriber.pending?.requiresImmediateRefresh == true)
            subscriber.continuation.yield(())
        }
    }

    private func cancelTimer() { timer?.task.cancel(); timer = nil }

    private func remove(_ id: UUID) {
        subscribers[id] = nil
        guard subscribers.isEmpty else { return }
        observer?.task.cancel(); observer = nil
        cancelTimer(); pending = []
    }
}
