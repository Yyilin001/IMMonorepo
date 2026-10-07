import Foundation
import Synchronization
import IMV2Core
import IMV2ServerContracts
import IMV2ServerApplication

/// A unique acquisition capability. Revocation is synchronous and follows the
/// original scope through delayed activation; it never names another owner.
final class V2RecoveryInterestTicket: Sendable {
    let key: V2RealtimeRecoveryKey
    let lifecycle: UInt64
    let generation: UInt64
    let ownerID = UUID()
    let interests: V2SharedGroupEventWakeInterests
    private struct State {
        var active = true
        var actualActivations = 0
        var acquired = false
        var drain: [CheckedContinuation<Void, Never>] = []
    }
    private let state = Mutex(State())

    init(key: V2RealtimeRecoveryKey, lifecycle: UInt64, generation: UInt64,
         interests: V2SharedGroupEventWakeInterests) {
        self.key = key; self.lifecycle = lifecycle; self.generation = generation; self.interests = interests
    }
    var isActive: Bool { state.withLock { $0.active } }
    var activationSettled: Bool { state.withLock { $0.actualActivations == 0 } }
    var isAcquired: Bool { state.withLock { $0.active && $0.acquired } }
    func revoke() { state.withLock { $0.active = false } }
    func beginActivation() -> Bool {
        state.withLock { state in
            guard state.active else { return false }
            state.actualActivations += 1
            return true
        }
    }
    func endActivation(succeeded: Bool = false) {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            precondition(state.actualActivations > 0)
            state.actualActivations -= 1
            if succeeded { state.acquired = true }
            guard state.actualActivations == 0 else { return [] }
            let result = state.drain; state.drain.removeAll(); return result
        }
        for waiter in waiters { waiter.resume() }
    }
    private func joinActivations() async {
        await withCheckedContinuation { continuation in
            state.withLock { state in
                if state.actualActivations == 0 { continuation.resume() }
                else { state.drain.append(continuation) }
            }
        }
    }
    var activation: V2SharedGroupEventWakeInterests.Activation {
        get throws { .init(roomID: try RoomID(key.id), scope: .account(ownerID)) }
    }
    func release() async {
        revoke()
        await joinActivations()
        guard let room = try? RoomID(key.id) else { return }
        await interests.manager(for: .account(ownerID)).deactivate(roomID: room)
    }
}

/// The UUID-backed topic IDs allow reuse of the established shared-interest
/// reconciliation without changing presence/typing publication or wire topics.
struct V2RecoveryLiveInterestAdapter: V2GroupEventWakeInterestManaging {
    let broker: any V2LiveActivityInterestManaging
    let presence: Bool
    func activate(roomID: RoomID) async throws {
        if presence { try await broker.activatePresence(targetUserID: UserID(roomID.rawValue)) }
        else { try await broker.activateTyping(roomID: roomID) }
    }
    func deactivate(roomID: RoomID) async {
        if presence, let user = try? UserID(roomID.rawValue) { await broker.deactivatePresence(targetUserID: user) }
        else if !presence { await broker.deactivateTyping(roomID: roomID) }
    }
}
