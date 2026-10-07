import Foundation
import IMV2ActorContracts
import IMV2Core
import IMV2ServerApplication

/// Owned by one room activation. Direct rooms bind exactly two durable
/// participants; group rooms retain bounded sending-account runtimes.
/// Group cache pressure seals idle senders and joins durable cleanup before
/// reclaiming a slot. Membership is checked by the actual room transaction.
actor PostgresV2RoomPolicyAuthorizationRegistry {
    typealias Loader = @Sendable (V2DirectSendControlPair, UUID, UUID) async throws -> V2RegisteredDirectPolicySnapshot
    nonisolated let activation: V2RoomActivationToken
    private let first: UUID?
    private let second: UUID?
    nonisolated let endpoint: String
    private let fence: PostgresV2RoomPolicyLeaseFence
    private let loader: Loader?
    private let accountLoader: (@Sendable (UUID, UUID, UUID) async throws -> V2RegisteredAccountPolicySnapshot)?
    private let currentLoader: (@Sendable (UUID, UUID?) async throws -> V2CurrentRoomPolicySnapshot)?
    private let maximumDirections: Int
    private let maximumRevocations: Int
    private var directions: [UUID: PostgresV2RoomPolicyAuthorization] = [:]
    private var recent: [UUID] = []
    private var eviction: Eviction?
    private var failedEvictions: Set<UUID> = []
    private var revocations: [UUID: Revocation] = [:]
    private var retirement: Task<Void, any Error>?
    private var closed = false

    private struct Revocation {
        let holder: V2PolicyAuthorizationHolder
        let task: Task<V2PolicyAuthorizationRevocationProof, any Error>
    }
    private struct Eviction {
        let sender: UUID
        let runtime: PostgresV2RoomPolicyAuthorization
        let task: Task<Bool, any Error>
    }

    init(activation: V2RoomActivationToken, participants: (UUID, UUID), endpoint: String,
         fence: PostgresV2RoomPolicyLeaseFence, maximumRevocations: Int = 16, loader: @escaping Loader) {
        precondition(participants.0 != participants.1 && maximumRevocations > 0)
        precondition(!endpoint.isEmpty && endpoint.utf8.count <= 512)
        self.activation = activation; first = participants.0; second = participants.1
        self.endpoint = endpoint; self.fence = fence; self.loader = loader
        self.accountLoader = nil; self.maximumDirections = 2
        self.currentLoader = nil
        self.maximumRevocations = maximumRevocations
    }

    init(activation: V2RoomActivationToken, endpoint: String, fence: PostgresV2RoomPolicyLeaseFence,
         maximumDirections: Int = 128, maximumRevocations: Int = 16,
         currentLoader: (@Sendable (UUID, UUID?) async throws -> V2CurrentRoomPolicySnapshot)? = nil,
         accountLoader: @escaping @Sendable (UUID, UUID, UUID) async throws -> V2RegisteredAccountPolicySnapshot) {
        precondition(!endpoint.isEmpty && endpoint.utf8.count <= 512 && maximumRevocations > 0 && maximumDirections > 0)
        self.activation = activation; self.first = nil; self.second = nil; self.endpoint = endpoint
        self.fence = fence; self.loader = nil; self.accountLoader = accountLoader
        self.maximumRevocations = maximumRevocations; self.maximumDirections = maximumDirections
        self.currentLoader = currentLoader
    }

    init(activation: V2RoomActivationToken, participants: (UUID, UUID), endpoint: String,
         fence: PostgresV2RoomPolicyLeaseFence,
         currentLoader: @escaping @Sendable (UUID, UUID?) async throws -> V2CurrentRoomPolicySnapshot) {
        precondition(participants.0 != participants.1 && !endpoint.isEmpty && endpoint.utf8.count <= 512)
        self.activation = activation; first = participants.0; second = participants.1
        self.endpoint = endpoint; self.fence = fence; self.loader = nil; self.accountLoader = nil
        self.maximumDirections = 2; self.maximumRevocations = 16; self.currentLoader = currentLoader
    }

    func runtime(sender: UUID, token: V2RoomActivationToken) async throws -> PostgresV2RoomPolicyAuthorization {
        try Task.checkCancellation()
        guard !closed else { throw V2PolicyAuthorizationLifecycleError.closed }
        guard token == activation else { throw V2PolicyAuthorizationLifecycleError.ownerChanged }
        if let first, let second {
            guard sender == first || sender == second else { throw V2PolicyAuthorizationLifecycleError.invalidTarget }
        }
        if let existing = directions[sender], !failedEvictions.contains(sender) {
            guard eviction?.sender != sender else { throw V2PolicyAuthorizationLifecycleError.busy }
            touch(sender)
            return existing
        }
        if directions.count >= maximumDirections || failedEvictions.contains(sender) {
            guard accountLoader != nil, eviction == nil else { throw V2PolicyAuthorizationLifecycleError.busy }
            // Only one actual retirement root per activation. Hits on other
            // senders remain available while a durable fence waits for SQL.
            let candidates = failedEvictions.contains(sender) ? [sender] : recent
            for candidate in candidates {
                guard !closed else { throw V2PolicyAuthorizationLifecycleError.closed }
                if directions.count < maximumDirections && !failedEvictions.contains(sender) { break }
                guard eviction == nil, let runtime = directions[candidate] else {
                    throw V2PolicyAuthorizationLifecycleError.busy
                }
                let task = Task.detached {
                    let result: Result<Bool, any Error>
                    do {
                        if await runtime.sealIfIdle() {
                            try await runtime.shutdown()
                            result = .success(true)
                        } else { result = .success(false) }
                    } catch { result = .failure(error) }
                    await self.evictionFinished(sender: candidate, runtime: runtime, result: result)
                    return try result.get()
                }
                eviction = .init(sender: candidate, runtime: runtime, task: task)
                _ = try await task.value
                try Task.checkCancellation()
            }
        }
        guard !closed else { throw V2PolicyAuthorizationLifecycleError.closed }
        if let existing = directions[sender] { touch(sender); return existing }
        guard directions.count < maximumDirections else { throw V2PolicyAuthorizationLifecycleError.busy }
        let runtime: PostgresV2RoomPolicyAuthorization
        if let first, let second, let currentLoader {
            let pair = V2DirectSendControlPair(sender: sender, recipient: sender == first ? second : first)
            runtime = .init(activation: activation, pair: pair, endpoint: endpoint, fence: fence,
                currentLoader: { try await currentLoader(sender, pair.recipient) },
                loader: { _, _ in throw V2PolicyAuthorizationLifecycleError.invalidRequest })
        } else if let first, let second, let loader {
            let pair = V2DirectSendControlPair(sender: sender, recipient: sender == first ? second : first)
            runtime = .init(activation: activation, pair: pair, endpoint: endpoint, fence: fence,
                loader: { registration, activation in try await loader(pair, registration, activation) })
        } else if let accountLoader {
            let loadCurrentAccount: PostgresV2RoomPolicyAuthorization.CurrentLoader?
            if let currentLoader { loadCurrentAccount = { try await currentLoader(sender, nil) } }
            else { loadCurrentAccount = nil }
            runtime = .init(activation: activation, groupSender: sender, endpoint: endpoint, fence: fence,
                currentLoader: loadCurrentAccount,
                loader: { registration, activation in try await accountLoader(sender, registration, activation) })
        } else { throw V2PolicyAuthorizationLifecycleError.invalidTarget }
        directions[sender] = runtime
        touch(sender)
        return runtime
    }

    /// Older activations and directions that never loaded are fenced directly
    /// in the room database. An expiry or a missing in-memory entry is no ACK.
    func revoke(_ holder: V2PolicyAuthorizationHolder) async throws -> V2PolicyAuthorizationRevocationProof {
        try Task.checkCancellation()
        guard holder.roomID == activation.roomID.uuidValue, holder.endpoint == endpoint else {
            throw V2PolicyAuthorizationLifecycleError.invalidTarget
        }
        if let existing = revocations[holder.registrationID] {
            guard existing.holder == holder else { throw V2PolicyAuthorizationLifecycleError.identityConflict }
            return try await existing.task.value
        }
        guard !closed else { throw V2PolicyAuthorizationLifecycleError.closed }
        guard revocations.count < maximumRevocations else { throw V2PolicyAuthorizationLifecycleError.busy }
        let runtime = directions.values.first { $0.activationID == holder.activationID }
        let fence = fence
        let task = Task.detached {
            let result: Result<V2PolicyAuthorizationRevocationProof, any Error>
            do {
                if let runtime {
                    do { result = .success(try await runtime.revoke(holder)) }
                    catch V2PolicyAuthorizationLifecycleError.closed { result = .success(try await fence.revoke(holder)) }
                }
                else { result = .success(try await fence.revoke(holder)) }
            } catch { result = .failure(error) }
            await self.revocationFinished(holder.registrationID)
            return try result.get()
        }
        revocations[holder.registrationID] = .init(holder: holder, task: task)
        return try await task.value
    }

    /// Close all directions and join actual SQL work before releasing resources.
    /// Callers cancelling their wait do not abandon activation retirement.
    func shutdown() async throws {
        if let retirement { return try await retirement.value }
        closed = true
        let runtimes = Array(directions.values), revocations = revocations.values.map(\.task)
        let eviction = eviction?.task
        let task = Task.detached {
            var failure: (any Error)?
            await withTaskGroup(of: (any Error)?.self) { group in
                for runtime in runtimes {
                    group.addTask {
                        do { try await runtime.shutdown(); return nil } catch { return error }
                    }
                }
                for await error in group { if failure == nil { failure = error } }
            }
            for task in revocations {
                if case .failure(let error) = await task.result, failure == nil { failure = error }
            }
            if let eviction, case .failure(let error) = await eviction.result, failure == nil { failure = error }
            if let failure { throw failure }
        }
        retirement = task
        do { try await task.value }
        catch {
            // Keep ingress closed, but allow durable cleanup to be retried
            // after a database failure. The failed root has already settled.
            retirement = nil
            throw error
        }
    }

    func pressure() -> (closed: Bool, directions: Int, revocations: Int) {
        (closed, directions.count, revocations.count)
    }

    func isEvicting() -> Bool { eviction != nil }

    private func touch(_ sender: UUID) {
        recent.removeAll { $0 == sender }
        recent.append(sender)
    }

    private func evictionFinished(sender: UUID, runtime: PostgresV2RoomPolicyAuthorization,
                                  result: Result<Bool, any Error>) {
        guard eviction?.sender == sender, eviction?.runtime === runtime else { return }
        eviction = nil
        if case .success(true) = result, directions[sender] === runtime {
            directions[sender] = nil
            recent.removeAll { $0 == sender }
            failedEvictions.remove(sender)
        }
        if case .failure = result { failedEvictions.insert(sender) }
        // A failed durable cleanup keeps the sealed entry and its capacity.
        // A later miss can retry cleanup; it cannot revive the old runtime.
    }

    private func revocationFinished(_ id: UUID) { revocations[id] = nil }
}
