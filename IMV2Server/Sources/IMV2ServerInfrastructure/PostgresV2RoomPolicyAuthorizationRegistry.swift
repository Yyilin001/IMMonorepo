import Foundation
import IMV2ActorContracts
import IMV2Core
import IMV2ServerApplication

/// Owned by one room activation. Direct rooms bind exactly two durable
/// participants; group rooms retain bounded sending-account runtimes.
/// Group cache pressure seals idle senders and joins actual work before
/// reclaiming a slot. Membership is checked by the actual room transaction.
actor PostgresV2RoomPolicyAuthorizationRegistry {
    nonisolated let activation: V2RoomActivationToken
    private let first: UUID?
    private let second: UUID?
    nonisolated let endpoint: String
    private let makeRuntime: @Sendable (UUID) -> PostgresV2RoomPolicyAuthorization
    private let maximumDirections: Int
    private var directions: [UUID: PostgresV2RoomPolicyAuthorization] = [:]
    private var recent: [UUID] = []
    private var eviction: Eviction?
    private var retirement: Task<Void, Never>?
    private var closed = false

    private struct Eviction {
        let sender: UUID
        let runtime: PostgresV2RoomPolicyAuthorization
        let task: Task<Bool, Never>
    }

    init(activation: V2RoomActivationToken, participants: (UUID, UUID)?, endpoint: String,
         maximumDirections: Int,
         makeRuntime: @escaping @Sendable (UUID) -> PostgresV2RoomPolicyAuthorization) {
        precondition(participants == nil || participants!.0 != participants!.1)
        precondition(!endpoint.isEmpty && endpoint.utf8.count <= 512 && maximumDirections > 0)
        self.activation = activation; first = participants?.0; second = participants?.1
        self.endpoint = endpoint; self.makeRuntime = makeRuntime
        self.maximumDirections = maximumDirections
    }

    init(activation: V2RoomActivationToken, participants: (UUID, UUID), endpoint: String,
         currentLoader: @escaping @Sendable (UUID, UUID?) async throws -> V2CurrentRoomPolicySnapshot) {
        self.init(activation: activation, participants: participants, endpoint: endpoint,
            maximumDirections: 2, makeRuntime: { sender in
                let pair = V2DirectSendControlPair(sender: sender,
                    recipient: sender == participants.0 ? participants.1 : participants.0)
                return .init(activation: activation, sender: sender, recipient: pair.recipient,
                    currentLoader: { try await currentLoader(sender, pair.recipient) })
            })
    }

    init(activation: V2RoomActivationToken, endpoint: String,
         maximumDirections: Int = 128,
         currentLoader: @escaping @Sendable (UUID, UUID?) async throws -> V2CurrentRoomPolicySnapshot) {
        self.init(activation: activation, participants: nil, endpoint: endpoint,
            maximumDirections: maximumDirections, makeRuntime: { sender in
                .init(activation: activation, sender: sender, recipient: nil,
                    currentLoader: { try await currentLoader(sender, nil) })
            })
    }

    func runtime(sender: UUID, token: V2RoomActivationToken) async throws -> PostgresV2RoomPolicyAuthorization {
        try Task.checkCancellation()
        guard !closed else { throw V2PolicyAuthorizationLifecycleError.closed }
        guard token == activation else { throw V2PolicyAuthorizationLifecycleError.ownerChanged }
        if let first, let second {
            guard sender == first || sender == second else { throw V2PolicyAuthorizationLifecycleError.invalidTarget }
        }
        if let existing = directions[sender] {
            guard eviction?.sender != sender else { throw V2PolicyAuthorizationLifecycleError.busy }
            touch(sender)
            return existing
        }
        if directions.count >= maximumDirections {
            guard first == nil, eviction == nil else { throw V2PolicyAuthorizationLifecycleError.busy }
            // Only one actual retirement root per activation. Hits on other
            // senders remain available while actual work settles.
            let candidates = recent
            for candidate in candidates {
                guard !closed else { throw V2PolicyAuthorizationLifecycleError.closed }
                if directions.count < maximumDirections { break }
                guard eviction == nil, let runtime = directions[candidate] else {
                    throw V2PolicyAuthorizationLifecycleError.busy
                }
                let task = Task.detached {
                    let retired = await runtime.sealIfIdle()
                    if retired { await runtime.shutdown() }
                    await self.evictionFinished(sender: candidate, runtime: runtime, retired: retired)
                    return retired
                }
                eviction = .init(sender: candidate, runtime: runtime, task: task)
                _ = await task.value
                try Task.checkCancellation()
            }
        }
        guard !closed else { throw V2PolicyAuthorizationLifecycleError.closed }
        if let existing = directions[sender] { touch(sender); return existing }
        guard directions.count < maximumDirections else { throw V2PolicyAuthorizationLifecycleError.busy }
        let runtime = makeRuntime(sender)
        directions[sender] = runtime
        touch(sender)
        return runtime
    }

    /// Close all directions and join actual SQL work before releasing resources.
    /// Callers cancelling their wait do not abandon activation retirement.
    func shutdown() async {
        if let retirement { return await retirement.value }
        closed = true
        let runtimes = Array(directions.values)
        let eviction = eviction?.task
        let task = Task.detached {
            await withTaskGroup(of: Void.self) { group in
                for runtime in runtimes { group.addTask { await runtime.shutdown() } }
            }
            if let eviction { _ = await eviction.value }
        }
        retirement = task
        await task.value
    }

    func pressure() -> (closed: Bool, directions: Int) {
        (closed, directions.count)
    }

    func isEvicting() -> Bool { eviction != nil }

    private func touch(_ sender: UUID) {
        recent.removeAll { $0 == sender }
        recent.append(sender)
    }

    private func evictionFinished(sender: UUID, runtime: PostgresV2RoomPolicyAuthorization,
                                  retired: Bool) {
        guard eviction?.sender == sender, eviction?.runtime === runtime else { return }
        eviction = nil
        if retired, directions[sender] === runtime {
            directions[sender] = nil
            recent.removeAll { $0 == sender }
        }
    }
}
