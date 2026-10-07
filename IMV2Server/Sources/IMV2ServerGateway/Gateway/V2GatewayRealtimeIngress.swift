import Foundation
import Synchronization
import IMV2ActorContracts
import IMV2ServerApplication
import IMV2ServerContracts
import IMV2Core

/// Actor RPC admission is synchronous and bounded. Local authorization and
/// socket work run only in the runtime-owned consumers after acceptance.
public final class V2GatewayRealtimeIngress: V2RealtimeIngress, Sendable {
    private enum Budget: Hashable, Sendable { case body, recovery, activity }
    private struct Work: Sendable { let delivery: V2RealtimeDelivery; let bytes: Int; let budget: Budget }
    private struct Usage: Sendable { var items = 0; var bytes = 0 }
    private struct State: Sendable {
        var coordinator: V2RealtimeInterestCoordinator?
        var queue: [Work] = []
        var offset = 0
        var usage: [Budget: Usage] = [:]
        var closed = false
        var consumers: [Task<Void, Never>] = []
    }
    private let state = Mutex(State())
    private let signal: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private let registry: V2DeviceConnectionRegistry
    private let metrics: V2ActorRealtimeMetrics?
    private let identity: V2GatewayRealtimeIdentity
    private let typing = Mutex(V2RealtimeTypingTracker())

    public init(identity: V2GatewayRealtimeIdentity, registry: V2DeviceConnectionRegistry, metrics: V2ActorRealtimeMetrics? = nil) {
        self.identity = identity; self.registry = registry; self.metrics = metrics
        let stream = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(4))
        signal = stream.stream; continuation = stream.continuation
    }
    public func start(coordinator: V2RealtimeInterestCoordinator) {
        state.withLock { value in
            precondition(value.coordinator == nil)
            value.coordinator = coordinator
            value.consumers = (0..<4).map { _ in Task { await self.consume() } }
        }
    }
    public func offer(_ batch: V2RealtimeBatch) -> V2RealtimeAcceptance {
        guard batch.recipient == identity else { return .stale }
        let accepted = state.withLock { value -> V2RealtimeAcceptance in
            guard !value.closed, let coordinator = value.coordinator else { return .closed }
            let deliveries = batch.deliveries
            guard !deliveries.isEmpty, deliveries.allSatisfy(coordinator.accepts) else { return .stale }
            var work: [Work] = []
            var degraded = 0
            var usage = value.usage
            for delivery in deliveries {
                var bytes = Self.bytes(delivery)
                var candidate = delivery
                var budget = Self.budget(delivery)
                if case .roomEvents(let events) = delivery.payload, let first = events.first,
                   !coordinator.isReady(delivery.topic) || bytes > 150_000 || !Self.fits(budget, adding: bytes, usage: usage) {
                    candidate = .init(topic: delivery.topic, partitionID: delivery.partitionID, partitionEpoch: delivery.partitionEpoch,
                        sessionID: delivery.sessionID, interestGeneration: delivery.interestGeneration,
                        gatewayIncarnation: delivery.gatewayIncarnation, payload: .roomWake(roomID: first.roomID,
                        highWatermark: events.map(\.highWatermark).max() ?? first.highWatermark))
                    bytes = 512; budget = .recovery; degraded += 1
                }
                guard Self.fits(budget, adding: bytes, usage: usage) else { return .overloaded }
                usage[budget, default: Usage()].items += 1
                usage[budget, default: Usage()].bytes += bytes
                work.append(.init(delivery: candidate, bytes: bytes, budget: budget))
            }
            value.usage = usage; value.queue.append(contentsOf: work)
            for item in work { metrics?.queue(Self.metricQueue(item.budget), items: 1, bytes: item.bytes) }
            for _ in 0..<degraded { metrics?.bodyDegraded() }
            return degraded > 0 ? .acceptedAsWatermark : .accepted
        }
        if accepted == .accepted || accepted == .acceptedAsWatermark { for _ in 0..<4 { continuation.yield(()) } }
        else { metrics?.admissionRejected() }
        return accepted
    }
    private static func metricQueue(_ budget: Budget) -> V2ActorRealtimeQueue {
        switch budget { case .body: return .body; case .recovery: return .recovery; case .activity: return .activity }
    }
    private static func budget(_ delivery: V2RealtimeDelivery) -> Budget {
        switch delivery.payload {
        case .roomEvents: return .body
        case .roomWake, .userSync: return .recovery
        case .presence, .typing: return .activity
        }
    }
    private static func fits(_ budget: Budget, adding bytes: Int, usage: [Budget: Usage]) -> Bool {
        let prior = usage[budget, default: Usage()]
        switch budget {
        case .body: return prior.items < 4_096 && prior.bytes + bytes <= 32 * 1_024 * 1_024
        case .recovery: return prior.items < 8_192 && prior.bytes + bytes <= 4 * 1_024 * 1_024
        case .activity: return prior.items < 2_048 && prior.bytes + bytes <= 1_024 * 1_024
        }
    }
    private static func bytes(_ delivery: V2RealtimeDelivery) -> Int {
        if case .roomEvents(let events) = delivery.payload { return events.reduce(512) { $0 + $1.payload.count + 512 } }
        return 512
    }
    private func next() -> Work? {
        state.withLock { value in
            guard !value.closed, value.offset < value.queue.count else { return nil }
            let work = value.queue[value.offset]; value.offset += 1
            if value.offset >= 256 { value.queue.removeFirst(value.offset); value.offset = 0 }
            return work
        }
    }
    private func consume() async {
        for await _ in signal {
            while let work = next() {
                let current = state.withLock { $0.coordinator?.accepts(work.delivery) == true && !$0.closed }
                let delivery = work.delivery
                if current {
                    // Retained scope validity must not capture event bodies
                    // after their ingress byte budget has been released.
                    let fence = V2RealtimeDelivery(topic: delivery.topic, partitionID: delivery.partitionID,
                        partitionEpoch: delivery.partitionEpoch, sessionID: delivery.sessionID,
                        interestGeneration: delivery.interestGeneration, gatewayIncarnation: delivery.gatewayIncarnation,
                        payload: .roomEvents([]))
                    let validity: @Sendable () -> Bool = { self.state.withLock {
                        !$0.closed && $0.coordinator?.accepts(fence) == true
                    } }
                    // Room payloads retain only recovery responsibility here.
                    // Physical Room Owner ingress owns actual body delivery.
                    if validity() {
                        switch delivery.payload {
                        case .roomWake, .roomEvents, .userSync: break
                        default: await process(delivery.payload)
                        }
                    }
                    if validity() {
                        await registry.applySharedRealtimeDelivery(delivery, isCurrent: validity)
                    }
                } else {
                    await registry.invalidateDurableRealtimeDelivery(delivery)
                }
                state.withLock {
                    $0.usage[work.budget, default: Usage()].bytes -= work.bytes
                    $0.usage[work.budget, default: Usage()].items -= 1
                    metrics?.queue(Self.metricQueue(work.budget), items: -1, bytes: -work.bytes)
                }
            }
        }
    }
    private func process(_ payload: V2RealtimePayload) async {
        switch payload {
        case .roomWake, .roomEvents, .userSync:
            break // Durable recovery handoff belongs to consume; bodies use Room Owner ingress.
        case .presence(let user):
            await registry.refreshObservedPresence(targetUserID: user)
        case .typing(let room, let user, let isTyping, let expires, let source, let sequence):
            let aggregate = typing.withLock {
                $0.observe(room: room, user: user, isTyping: isTyping, expiresAt: expires,
                    source: source, sequence: sequence, now: Date())
            }
            if let aggregate { await registry.receiveTyping(aggregate) }
        }
    }
    public func shutdown() async {
        let tasks = state.withLock { value -> [Task<Void, Never>] in
            value.closed = true
            for work in value.queue.dropFirst(value.offset) {
                value.usage[work.budget, default: Usage()].bytes -= work.bytes
                value.usage[work.budget, default: Usage()].items -= 1
                metrics?.queue(Self.metricQueue(work.budget), items: -1, bytes: -work.bytes)
            }
            value.queue.removeAll(); value.offset = 0
            return value.consumers
        }
        continuation.finish()
        for task in tasks { await task.value }
    }
}

/// Source-local order and user-level aggregation are separate. An explicit stop
/// from one socket must not clear a sibling socket that is still typing.
struct V2RealtimeTypingTracker: Sendable {
    private struct Source: Sendable {
        let room: RoomID; let user: UserID; let sequence: UInt64; let expiresAt: Date; let isTyping: Bool
    }
    private var sources: [String: Source] = [:]
    mutating func observe(room: RoomID, user: UserID, isTyping: Bool, expiresAt: Date,
                          source: UUID, sequence: UInt64, now: Date) -> V2TypingState? {
        guard expiresAt > now, expiresAt <= now.addingTimeInterval(12), sequence > 0 else { return nil }
        let key = source.uuidString + ":" + room.rawValue + ":" + user.rawValue
        sources = sources.filter { $0.value.expiresAt > now }
        guard sequence > (sources[key]?.sequence ?? 0), sources[key] != nil || sources.count < 4_096 else { return nil }
        sources[key] = .init(room: room, user: user, sequence: sequence, expiresAt: expiresAt, isTyping: isTyping)
        let active = sources.values.filter { $0.room == room && $0.user == user && $0.isTyping }
        return .init(roomID: room, userID: user, isTyping: !active.isEmpty,
            expiresAt: active.map(\.expiresAt).max() ?? now)
    }
}
