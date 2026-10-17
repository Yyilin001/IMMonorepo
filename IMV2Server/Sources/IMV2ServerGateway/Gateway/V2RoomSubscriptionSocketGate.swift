import Foundation
import Synchronization
@preconcurrency import NIOCore
import IMV2Core
import IMV2ActorContracts

/// Only the connection EventLoop reads/mutates this projection at socket enqueue.
/// Room actors publish updates before acknowledging their control operation.
final class V2RoomSubscriptionSocketGate: Sendable {
    struct RoomPermission: Sendable, Equatable {
        let fence: V2RoomSubscriptionFence?
        let session: V2RoomDeliverySessionGate?
        let authorizationID: UUID?
        let memberRevision: UInt64?
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.fence == rhs.fence && lhs.session === rhs.session
                && lhs.authorizationID == rhs.authorizationID && lhs.memberRevision == rhs.memberRevision
        }
        static let denied = Self(fence: nil, session: nil, authorizationID: nil, memberRevision: nil)
    }
    private struct HeadScope: Equatable {
        let fence: V2RoomSubscriptionFence
        let lifecycle: UUID
        let generation: UInt64
        let authorizationID: UUID
        let memberRevision: UInt64
    }
    private final class State {
        var lifecycle: UUID?
        var interest: (RoomID, UInt64)?
        var rooms: [RoomID: RoomPermission] = [:]
        var closed = false
        var submittedHead: (HeadScope, UInt64)?
    }
    let eventLoop: any EventLoop
    private let state: NIOLoopBound<State>
    init(eventLoop: any EventLoop) {
        precondition(eventLoop.inEventLoop)
        self.eventLoop = eventLoop
        self.state = .init(State(), eventLoop: eventLoop)
    }
    func register(lifecycle: UUID) -> EventLoopFuture<Void> {
        eventLoop.submit { [state] in
            guard !state.value.closed else { return }
            if state.value.lifecycle != lifecycle { state.value.rooms.removeAll(); state.value.interest = nil; state.value.submittedHead = nil }
            state.value.lifecycle = lifecycle
        }
    }
    func interest(lifecycle: UUID, roomID: RoomID?, generation: UInt64 = 0) -> EventLoopFuture<Void> {
        eventLoop.submit { [state] in
            guard !state.value.closed, state.value.lifecycle == lifecycle else { return }
            if state.value.interest?.0 != roomID || state.value.interest?.1 != generation {
                state.value.submittedHead = nil
            }
            state.value.interest = roomID.map { ($0, generation) }
        }
    }
    func install(roomID: RoomID, permission: RoomPermission) -> EventLoopFuture<Void> {
        eventLoop.submit { [state] in
            guard !state.value.closed else { return }
            if permission == .denied { state.value.rooms.removeValue(forKey: roomID) }
            else { state.value.rooms[roomID] = permission }
        }
    }
    func close() -> EventLoopFuture<Void> {
        eventLoop.submit { [state] in
            state.value.closed = true; state.value.rooms.removeAll(); state.value.interest = nil; state.value.submittedHead = nil
        }
    }
    func enqueue(_ permit: V2GatewayRoomSubscriptionAuthority.Permit,
                 now: ContinuousClock.Instant, body: @Sendable () -> Void) -> Bool {
        precondition(eventLoop.inEventLoop)
        let value = state.value
        guard !value.closed, value.lifecycle == permit.lifecycle,
              let room = value.rooms[permit.fence.roomID], room.fence == permit.fence,
              room.session?.isReady() == true,
              room.authorizationID == permit.authorizationID,
              room.memberRevision == permit.memberRevision else { return false }
        if permit.requiresRoomInterest {
            guard let interest = value.interest, interest.0 == permit.fence.roomID,
                  interest.1 == permit.scopeGeneration else { return false }
        }
        body(); return true
    }
    func resetSubmittedHead() {
        precondition(eventLoop.inEventLoop)
        state.value.submittedHead = nil
    }
    // Called only after the exact socket permit admitted a real channel write.
    // This is a sent hint, never an applied/contiguous client cursor.
    func recordSubmittedHead(_ permit: V2GatewayRoomSubscriptionAuthority.Permit, highWatermark: UInt64) {
        guard let scope = headScope(permit) else { return }
        let old = state.value.submittedHead
        state.value.submittedHead = (scope, old?.0 == scope ? max(old!.1, highWatermark) : highWatermark)
    }
    func hasSubmittedHead(_ permit: V2GatewayRoomSubscriptionAuthority.Permit, highWatermark: UInt64) -> Bool {
        guard let scope = headScope(permit), let old = state.value.submittedHead else { return false }
        return old.0 == scope && old.1 >= highWatermark
    }
    private func headScope(_ permit: V2GatewayRoomSubscriptionAuthority.Permit) -> HeadScope? {
        precondition(eventLoop.inEventLoop)
        guard !state.value.closed, state.value.lifecycle == permit.lifecycle,
              let interest = state.value.interest, interest.0 == permit.fence.roomID else { return nil }
        if permit.requiresRoomInterest && interest.1 != permit.scopeGeneration { return nil }
        return .init(fence: permit.fence, lifecycle: permit.lifecycle, generation: interest.1,
                     authorizationID: permit.authorizationID, memberRevision: permit.memberRevision)
    }
    func enqueueInterest(lifecycle: UUID, roomID: RoomID, generation: UInt64,
                         body: @Sendable () -> Void) -> Bool {
        precondition(eventLoop.inEventLoop)
        guard !state.value.closed, state.value.lifecycle == lifecycle,
              let interest = state.value.interest, interest.0 == roomID, interest.1 == generation else { return false }
        body(); return true
    }
}
