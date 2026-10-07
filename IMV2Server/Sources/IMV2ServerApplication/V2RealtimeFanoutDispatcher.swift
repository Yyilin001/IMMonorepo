import Foundation
import IMV2Core
import IMV2ActorContracts
import IMV2ServerContracts

/// Publication has independent durable/transient gates. The shard's delivery
/// gate is another object; a two-hop publish never waits for its own permits.
public actor V2RealtimeFanoutDispatcher {
    public enum Failure: Error { case overloaded, rejected, closed, locationUnknown }
    private let transport: any V2RealtimeShardTransport
    private let metrics: V2ActorRealtimeMetrics?
    private var durable = 0
    private var transient = 0
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []
    private var closed = false
    public init(transport: any V2RealtimeShardTransport, metrics: V2ActorRealtimeMetrics? = nil) {
        self.transport = transport; self.metrics = metrics
    }
    public func publish(topic: V2RealtimeTopic, payload: V2RealtimePayload) async throws {
        guard !closed else { throw Failure.closed }
        let persistent = topic.kind == .roomEvents || topic.kind == .userSync
        guard persistent ? durable < 8 : transient < 4 else { throw V2RealtimePublicationBackpressure.globalRPCs }
        if persistent { durable += 1 } else { transient += 1 }
        defer {
            if persistent { durable -= 1 } else { transient -= 1 }
            if durable + transient == 0 { let old = drainWaiters; drainWaiters.removeAll(); for waiter in old { waiter.resume() } }
        }
        let route = try await transport.resolve(partitionID: V2RealtimeTopicKey(topic).partitionID())
        try await send(topic: topic, payload: payload, route: route)
    }
    private func send(topic: V2RealtimeTopic, payload: V2RealtimePayload, route: V2RealtimeShardDescriptor) async throws {
        let reply: V2RealtimeShardPublishReply
        do { reply = try await transport.publish(route, request: .init(token: route.token, topic: topic, payload: payload)) }
        catch let error as V2RealtimeLocalAdmissionBackpressure {
            switch error {
            case .globalRPCs: throw V2RealtimePublicationBackpressure.globalRPCs
            case .peerRPCs: throw V2RealtimePublicationBackpressure.peerRPCs
            }
        }
        switch reply {
        case .noSubscribers: return
        case .accepted: metrics?.rpc(.accepted)
        case .acceptedAsWatermark: metrics?.rpc(.acceptedAsWatermark)
        case .overloaded: throw V2RealtimePublicationBackpressure.receiverQueue
        case .retiredEpoch, .retiredIncarnation: await transport.invalidate(route); throw Failure.locationUnknown
        case .notInstalled: throw Failure.locationUnknown
        }
    }
    private struct PreparedPublication: Sendable {
        let topic: V2RealtimeTopic
        let payload: V2RealtimePayload
        let route: V2RealtimeShardDescriptor
    }
    private enum BatchEvent: Sendable {
        case prepared(Int, Result<PreparedPublication, any Error>)
        case settled(V2GatewayRealtimeIdentity?, Result<Void, any Error>)
    }
    /// One owned pass: preparation and publication share eight actual children.
    /// Only known prepared candidates use ordinal order; unresolved rooms have
    /// no cross-room FIFO contract. The native gate remains authoritative.
    func publishBatch(count: Int,
        prepare: @escaping @Sendable (Int) async throws -> (V2RealtimeTopic, V2RealtimePayload),
        onSettled: @escaping @Sendable (Int, Result<Void, any Error>) async throws -> Void
    ) async throws {
        guard !closed else { throw Failure.closed }
        let transport = transport
        let terminal = await withTaskGroup(of: BatchEvent.self) { group in
            var ready = [PreparedPublication?](repeating: nil, count: count)
            var next = 0, active = 0
            var peers: [V2GatewayRealtimeIdentity: Int] = [:]
            var terminal: (any Error)?
            while true {
                if Task.isCancelled, terminal == nil { terminal = CancellationError() }
                while terminal == nil, active < 8 {
                    if let index = ready.indices.first(where: { index in
                        guard let value = ready[index] else { return false }
                        return peers[value.route.endpoint.identity, default: 0] < 2
                    }), let value = ready[index] {
                        ready[index] = nil
                        let peer = value.route.endpoint.identity
                        peers[peer, default: 0] += 1; active += 1
                        group.addTask {
                            let result: Result<Void, any Error>
                            do { try Task.checkCancellation(); try await self.publishPrepared(value); result = .success(()) }
                            catch { result = .failure(error) }
                            do {
                                if case .failure(let error) = result, error is CancellationError { throw error }
                                try await onSettled(index, result)
                                return .settled(peer, .success(()))
                            } catch { return .settled(peer, .failure(error)) }
                        }
                    } else if next < count {
                        let index = next; next += 1; active += 1
                        group.addTask {
                            do {
                                try Task.checkCancellation()
                                let (topic, payload) = try await prepare(index)
                                let route = try await transport.resolve(partitionID: V2RealtimeTopicKey(topic).partitionID())
                                return .prepared(index, .success(.init(topic: topic, payload: payload, route: route)))
                            } catch { return .prepared(index, .failure(error)) }
                        }
                    } else { break }
                }
                guard active > 0, let event = await group.next() else { break }
                active -= 1
                switch event {
                case .prepared(let index, .success(let value)):
                    if terminal == nil { ready[index] = value }
                case .prepared(let index, .failure(let error)):
                    if error is CancellationError { if terminal == nil { terminal = error } }
                    else if terminal == nil {
                        // Persistence callbacks are actual children too, and a
                        // fatal callback prevents new dispatch without dropping
                        // already submitted publications or their callbacks.
                        active += 1
                        group.addTask {
                            do { try await onSettled(index, .failure(error)); return .settled(nil, .success(())) }
                            catch { return .settled(nil, .failure(error)) }
                        }
                    }
                case .settled(let peer, let result):
                    if let peer { peers[peer, default: 1] -= 1 }
                    if case .failure(let error) = result, terminal == nil { terminal = error }
                }
            }
            return terminal
        }
        if let terminal { throw terminal }
    }
    private func publishPrepared(_ value: PreparedPublication) async throws {
        guard !closed else { throw Failure.closed }
        guard durable < 8 else { throw V2RealtimePublicationBackpressure.globalRPCs }
        durable += 1
        defer {
            durable -= 1
            if durable + transient == 0 { let old = drainWaiters; drainWaiters.removeAll(); for waiter in old { waiter.resume() } }
        }
        // No resolve here: the original exact descriptor/token is revalidated
        // by Transport.publish immediately before native admission.
        try await send(topic: value.topic, payload: value.payload, route: value.route)
    }
    public func shutdown() async {
        closed = true
        if durable + transient > 0 { await withCheckedContinuation { drainWaiters.append($0) } }
    }
}

/// Business-to-wire conversion preserves commit-time audiences and both member
/// fences; no subscriber list is ever used to invent content authorization.
public extension V2RealtimeRoomEvent {
    init(_ event: V2DirectRoomLiveEvent) {
        self.init(roomID: event.roomID, highWatermark: event.highWatermark, sourceEventID: event.sourceEventID,
            roomSequence: event.roomSequence, projectionKind: event.projectionKind, payload: event.payload,
            recipientUserIDs: event.recipientUserIDs, groupMembershipRevision: event.groupMembershipRevision,
            acceptedMembershipRevision: event.acceptedMembershipRevision, excludedConnectionID: event.excludedConnectionID)
    }
    var localEvent: V2DirectRoomLiveEvent {
        .init(roomID: roomID, highWatermark: highWatermark, sourceEventID: sourceEventID,
            roomSequence: roomSequence, projectionKind: projectionKind, payload: payload,
            recipientUserIDs: recipientUserIDs, groupMembershipRevision: groupMembershipRevision,
            acceptedMembershipRevision: acceptedMembershipRevision, excludedConnectionID: excludedConnectionID)
    }
}

public protocol V2LifecycleTypingPublishing: Sendable {
    func publishTyping(_ state: V2TypingState, sourceConnectionID: UUID) async
}

public struct V2ActorRealtimePublisher: V2GroupEventWakePublishing,
    V2LiveActivityInterestManaging, V2LiveActivityPublishing, V2LifecycleTypingPublishing, V2UserSyncWakePublishing, Sendable {
    public typealias TopicResolver = @Sendable (V2RealtimeTopicKind, String) async throws -> V2RealtimeTopic
    private let interests: V2RealtimeInterestCoordinator
    private let fanout: V2RealtimeFanoutDispatcher
    private let topic: TopicResolver
    private let sourceID: UUID
    private let typingSequence: V2RealtimeSequence
    public init(interests: V2RealtimeInterestCoordinator, fanout: V2RealtimeFanoutDispatcher,
                topic: @escaping TopicResolver) {
        self.interests = interests; self.fanout = fanout; self.topic = topic
        self.sourceID = UUID(); self.typingSequence = V2RealtimeSequence()
    }
    public func activatePresence(targetUserID: UserID) async throws {
        try await interests.activate(topic(.userPresence, targetUserID.rawValue))
    }
    public func deactivatePresence(targetUserID: UserID) async {
        if let topic = try? await topic(.userPresence, targetUserID.rawValue) { await interests.deactivate(topic) }
    }
    public func activateTyping(roomID: RoomID) async throws {
        try await interests.activate(topic(.roomTyping, roomID.rawValue))
    }
    public func deactivateTyping(roomID: RoomID) async {
        if let topic = try? await topic(.roomTyping, roomID.rawValue) { await interests.deactivate(topic) }
    }
    public func activateUser(userID: UserID) async throws { try await interests.activate(topic(.userSync, userID.rawValue)) }
    public func deactivateUser(userID: UserID) async { if let topic = try? await topic(.userSync, userID.rawValue) { await interests.deactivate(topic) } }
    /// A relay/commit observer already knows the actual data owner. Avoid a
    /// second business routing lookup just to construct its signed envelope.
    public func publish(_ wake: V2GroupEventWake, dataOwner: V2RoomDataOwner) async throws {
        try await fanout.publish(topic: .init(kind: .roomEvents, id: wake.roomID.rawValue, owner: dataOwner),
            payload: .roomWake(roomID: wake.roomID, highWatermark: wake.highWatermark))
    }
    public func publishBatch(_ wakes: [V2GroupEventWake],
        onSettled: @escaping @Sendable (Int, Result<Void, any Error>) async throws -> Void
    ) async throws {
        let topic = topic
        try await fanout.publishBatch(count: wakes.count, prepare: { index in
            let wake = wakes[index]
            return (try await topic(.roomEvents, wake.roomID.rawValue),
                .roomWake(roomID: wake.roomID, highWatermark: wake.highWatermark))
        }, onSettled: onSettled)
    }
    public func publish(_ wake: V2UserSyncWake, dataOwner: V2RoomDataOwner) async throws {
        let user = try UserID(wake.userID)
        try await fanout.publish(topic: .init(kind: .userSync, id: user.rawValue, owner: dataOwner),
            payload: .userSync(userID: user, highWatermark: wake.highWatermark))
    }
    public func publish(_ wake: V2GroupEventWake) async throws {
        try await fanout.publish(topic: topic(.roomEvents, wake.roomID.rawValue), payload: .roomWake(roomID: wake.roomID, highWatermark: wake.highWatermark))
    }
    public func publish(_ wake: V2UserSyncWake) async throws {
        let user = try UserID(wake.userID)
        try await fanout.publish(topic: topic(.userSync, user.rawValue), payload: .userSync(userID: user, highWatermark: wake.highWatermark))
    }
    public func publishPresence(targetUserID: UserID, isOnline: Bool, expiresAt: Date) async {
        try? await fanout.publish(topic: topic(.userPresence, targetUserID.rawValue), payload: .presence(userID: targetUserID))
    }
    public func publishTyping(_ state: V2TypingState) async { await publishTyping(state, sourceConnectionID: sourceID) }
    public func publishTyping(_ state: V2TypingState, sourceConnectionID: UUID) async {
        let now = Date()
        guard !state.isTyping || state.expiresAt > now else { return }
        let validUntil = state.isTyping ? state.expiresAt : now.addingTimeInterval(6)
        let sequence = await typingSequence.next()
        try? await fanout.publish(topic: topic(.roomTyping, state.roomID.rawValue), payload: .typing(roomID: state.roomID,
            userID: state.userID, isTyping: state.isTyping, expiresAt: validUntil, sourceConnectionID: sourceConnectionID, sequence: sequence))
    }
}
private actor V2RealtimeSequence {
    var value: UInt64 = 0
    func next() -> UInt64 { value += 1; return value }
}
