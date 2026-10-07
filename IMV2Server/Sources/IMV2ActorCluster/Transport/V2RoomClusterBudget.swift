import Synchronization
import Foundation
import IMV2ActorContracts

/// Node-wide capacity survives Peer partitioning; permits live through actual work settlement.
final class V2RoomClusterBudget: Sendable {
    enum Kind: Hashable, Sendable { case exchange, transport, waiter, recovery, reservation, session }
    final class Permit: Sendable {
        private let budget: V2RoomClusterBudget
        private let kind: Kind
        private let expirationID: UUID?
        private let held = Mutex(true)
        init(budget: V2RoomClusterBudget, kind: Kind, expirationID: UUID?) { self.budget = budget; self.kind = kind; self.expirationID = expirationID }
        func release() {
            let release = held.withLock { value in
                guard value else { return false }; value = false; return true
            }
            if release { budget.release(kind, expirationID: expirationID) }
        }
        deinit { release() }
    }
    private let limits: [Kind: Int]
    private struct State: Sendable {
        var counts: [Kind: Int] = [:]
        var expirations: [UUID: (Kind, ContinuousClock.Instant)] = [:]
    }
    private let state = Mutex(State())
    init(configuration: V2RoomRuntimeConfiguration, maximumSessions: Int) {
        limits = [.exchange: configuration.maximumActivationWaitersPerHost,
            .transport: configuration.maximumActivationWaitersPerHost,
            .waiter: configuration.maximumActivationWaitersPerHost,
            .recovery: 4, .reservation: configuration.maximumConcurrentReservations,
            .session: maximumSessions]
    }
    func acquire(_ kind: Kind, expiresAt: ContinuousClock.Instant? = nil) throws -> Permit {
        let expirationID = expiresAt.map { _ in UUID() }
        try state.withLock { value in
            let expired = value.expirations.filter { $0.value.1 <= .now }
            for (id, entry) in expired { value.expirations[id] = nil; value.counts[entry.0, default: 0] -= 1 }
            guard value.counts[kind, default: 0] < limits[kind]! else { throw V2RoomCallFailure.notAccepted(.overloaded) }
            value.counts[kind, default: 0] += 1
            if let expirationID, let expiresAt { value.expirations[expirationID] = (kind, expiresAt) }
        }
        return Permit(budget: self, kind: kind, expirationID: expirationID)
    }
    private func release(_ kind: Kind, expirationID: UUID?) {
        state.withLock {
            if let expirationID, $0.expirations.removeValue(forKey: expirationID) == nil { return }
            $0.counts[kind, default: 0] -= 1
        }
    }
}
