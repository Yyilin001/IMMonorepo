import Foundation
import IMV2ClientKit

/// 页面级投影失效通知器。
///
/// 普通提交共享 150 毫秒的合并窗口；安全类变更会立即冲刷待处理并集。
/// 计时器与 SQLite 读取器都属于当前订阅者集合，不会比该集合存续更久。
actor V2ProjectionChangeNotifier {
    /// 一次失效请求。
    struct Request: Equatable, Sendable {
        /// 产生该请求的投影代次。
        let generation: UInt64
        /// 是否要求立即刷新。
        let requiresImmediateRefresh: Bool
        let conversationCommit: V2ConversationCommitMeasurement?
        let scopes: V2ProjectionScopes
        let roomIDs: Set<String>?
        init(generation: UInt64, requiresImmediateRefresh: Bool, conversationCommit: V2ConversationCommitMeasurement? = nil,
             scopes: V2ProjectionScopes = .all, roomIDs: Set<String>? = nil) {
            self.generation = generation; self.requiresImmediateRefresh = requiresImmediateRefresh
            self.conversationCommit = conversationCommit; self.scopes = scopes; self.roomIDs = roomIDs
        }
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.generation == rhs.generation && lhs.requiresImmediateRefresh == rhs.requiresImmediateRefresh && lhs.scopes == rhs.scopes && lhs.roomIDs == rhs.roomIDs
        }
    }
    /// 单个订阅者的失效请求流。
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
        let roomID: String?
        let continuation: AsyncStream<Void>.Continuation
        var pending: Request?
    }
    private let localStore: GRDBV2LocalSyncStore?
    private let sleep: @Sendable (Duration) async throws -> Void
    private var generation: UInt64 = 0
    private var subscribers: [UUID: Subscriber] = [:]
    private var pending: V2ProjectionScopes = []
    private var pendingConversationCommit: V2ConversationCommitMeasurement?
    private var pendingRoomIDs: Set<String>?
    private var timer: (id: UUID, task: Task<Void, Never>)?
    private var observer: (id: UUID, task: Task<Void, Never>)?
    private var closed = false

    init(localStore: GRDBV2LocalSyncStore? = nil,
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.localStore = localStore
        self.sleep = sleep
    }

    deinit { observer?.task.cancel(); timer?.task.cancel() }

    func updates(scopes: V2ProjectionScopes = .all, roomID: String? = nil) -> Subscription {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let subscription = Subscription(id: id, notifier: self, wakes: stream)
        guard !closed else { continuation.finish(); return subscription }
        subscribers[id] = .init(scopes: scopes, roomID: roomID, continuation: continuation, pending: nil)
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

    /// 发布一次失效。
    ///
    /// 也支持持有者显式发起的失效；未知变更默认走全量立即刷新，而绝不会落到延迟路径。
    ///
    /// - Parameter change: 待发布的变更摘要，默认全量。
    func publish(_ change: V2ProjectionChange = .all) {
        guard !closed, !change.scopes.isEmpty else { return }
        let hadPendingChanges = !pending.isEmpty
        pending.formUnion(change.scopes)
        pendingRoomIDs = hadPendingChanges ? Self.mergeRoomIDs(pendingRoomIDs, change.roomIDs) : change.roomIDs
        pendingConversationCommit = V2ConversationCommitMeasurement.earliest(pendingConversationCommit, change.conversationCommit)
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
        cancelTimer(); pending = []; pendingConversationCommit = nil; pendingRoomIDs = nil
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
        let roomIDs = pendingRoomIDs
        let conversationCommit = pendingConversationCommit
        pendingConversationCommit = nil
        pending = []
        pendingRoomIDs = nil
        generation &+= 1
        for (id, subscriber) in subscribers where Self.matches(subscriber, scopes: scopes, roomIDs: roomIDs) {
            // A busy consumer may receive an ordinary update after an urgent
            // one. Replacing its wake must not downgrade pending urgency.
            let previous = subscriber.pending
            subscribers[id]?.pending = .init(generation: generation,
                requiresImmediateRefresh: requiresImmediateRefresh || subscriber.pending?.requiresImmediateRefresh == true,
                conversationCommit: V2ConversationCommitMeasurement.earliest(conversationCommit, subscriber.pending?.conversationCommit),
                scopes: (previous?.scopes ?? []).union(scopes),
                roomIDs: previous.map { Self.mergeRoomIDs(roomIDs, $0.roomIDs) } ?? roomIDs)
            subscriber.continuation.yield(())
        }
    }

    private func cancelTimer() { timer?.task.cancel(); timer = nil }

    private static func matches(_ subscriber: Subscriber, scopes: V2ProjectionScopes, roomIDs: Set<String>?) -> Bool {
        let detail: V2ProjectionScopes = [.conversationDetails, .conversationTimeline, .conversationMetadata]
        let incoming = scopes.contains(.conversationDetails) ? scopes.union([.conversationTimeline, .conversationMetadata]) : scopes
        let requested = subscriber.scopes.contains(.conversationDetails) ? subscriber.scopes.union([.conversationTimeline, .conversationMetadata]) : subscriber.scopes
        guard !requested.intersection(incoming).isEmpty else { return false }
        guard let roomIDs, let roomID = subscriber.roomID, !incoming.intersection(detail).isEmpty else { return true }
        return roomIDs.contains(roomID)
    }

    private static func mergeRoomIDs(_ lhs: Set<String>?, _ rhs: Set<String>?) -> Set<String>? {
        guard let lhs, let rhs else { return nil }
        let merged = lhs.union(rhs)
        return merged.count <= 32 ? merged : nil
    }

    private func remove(_ id: UUID) {
        subscribers[id] = nil
        guard subscribers.isEmpty else { return }
        observer?.task.cancel(); observer = nil
        cancelTimer(); pending = []; pendingConversationCommit = nil; pendingRoomIDs = nil
    }
}
