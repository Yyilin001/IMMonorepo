import Foundation
import FluentKit
import IMV2ActorContracts
import IMV2Core
import IMV2ServerApplication
import IMV2ServerContracts
import SQLKit

fileprivate actor V2CurrentPolicyExecutionLifetime {
    private var active = true
    func requireActive() throws {
        guard active else { throw V2RoomPolicyAuthorizationGate.Failure.invalidPermit }
    }
    func settled() { active = false }
}

/// Opaque command-bound ownership. The room writer still checks activation,
/// membership, reply markers, special-account rules and quota in its transaction.
struct V2RoomPolicyExecution: Sendable {
    private let commands: [ClientMessageID: V2SendMessageCommand]
    let snapshot: V2RoomPolicySnapshot
    let activation: V2RoomActivationToken
    private let gate: V2RoomPolicyAuthorizationGate?
    private let permit: V2RoomPolicyAuthorizationGate.Permit?
    private let currentLifetime: V2CurrentPolicyExecutionLifetime?
    private let fence: PostgresV2RoomPolicyLeaseFence

    fileprivate init(commands: [ClientMessageID: V2SendMessageCommand], snapshot: V2RegisteredRoomPolicySnapshot,
                     activation: V2RoomActivationToken, gate: V2RoomPolicyAuthorizationGate,
                     permit: V2RoomPolicyAuthorizationGate.Permit, fence: PostgresV2RoomPolicyLeaseFence) {
        self.commands = commands; self.snapshot = .registered(snapshot); self.activation = activation
        self.gate = gate; self.permit = permit; self.fence = fence
        self.currentLifetime = nil
    }

    fileprivate init(commands: [ClientMessageID: V2SendMessageCommand], snapshot: V2CurrentRoomPolicySnapshot,
                     activation: V2RoomActivationToken, fence: PostgresV2RoomPolicyLeaseFence,
                     lifetime: V2CurrentPolicyExecutionLifetime) {
        self.commands = commands; self.snapshot = .current(snapshot); self.activation = activation
        self.gate = nil; self.permit = nil; self.fence = fence
        self.currentLifetime = lifetime
    }

    private func requireExecuting() async throws {
        if let gate, let permit { try await gate.requireExecuting(permit) }
        if let currentLifetime { try await currentLifetime.requireActive() }
    }

    func validate(_ command: V2SendMessageCommand) throws {
        guard let original = commands[command.clientMessageID], command == original,
              command.fingerprint.version == 3 else {
            throw V2DirectAuthorizationIntentError.identityConflict
        }
    }

    func requireActive(roomID: UUID, senderID: UUID, clientMessageID: UUID, sql: any SQLDatabase) async throws {
        guard let command = commands[.init(uuid: clientMessageID)],
              command.roomID.uuidValue == roomID, command.senderUserID.uuidValue == senderID,
              let transaction = sql as? any Database else {
            throw V2DirectAuthorizationIntentError.identityConflict
        }
        try await requireExecuting()
        if case .registered(let snapshot) = snapshot {
            try await fence.requireActive(snapshot.holder, transaction: transaction)
        }
    }

    static func requireActive(_ inputs: [(execution: Self, command: V2SendMessageCommand)], sql: any SQLDatabase) async throws {
        guard !inputs.isEmpty, inputs.count <= 256, let transaction = sql as? any Database else {
            throw V2PolicyAuthorizationLifecycleError.invalidRequest
        }
        for input in inputs {
            try input.execution.validate(input.command)
            try await input.execution.requireExecuting()
        }
        let registered = inputs.compactMap { input -> (Self, V2PolicyAuthorizationHolder)? in
            if case .registered(let snapshot) = input.execution.snapshot { return (input.execution, snapshot.holder) }
            return nil
        }
        if let first = registered.first {
            try await first.0.fence.requireActive(registered.map { $0.1 }, transaction: transaction)
        }
    }

    static func combinedFenceCheck(_ inputs: [(execution: Self, command: V2SendMessageCommand)]) async throws
        -> PostgresV2RoomPolicyLeaseFence.CombinedCheck? {
        guard !inputs.isEmpty else { return nil }
        guard inputs.count <= 256 else { throw V2PolicyAuthorizationLifecycleError.invalidRequest }
        for input in inputs {
            try input.execution.validate(input.command)
            try await input.execution.requireExecuting()
        }
        let registered = inputs.compactMap { input -> (Self, V2PolicyAuthorizationHolder)? in
            if case .registered(let snapshot) = input.execution.snapshot { return (input.execution, snapshot.holder) }
            return nil
        }
        guard let first = registered.first else { return nil }
        return try first.0.fence.combinedCheck(registered.map { $0.1 })
    }
}

/// Cold preparation is a snapshot witness, not an executing permit. Queues
/// retain this immutable handle without adding roots to the room gate.
struct V2RoomPolicyPreparation: Sendable {
    let runtime: PostgresV2RoomPolicyAuthorization
    let activation: V2RoomActivationToken
    let deadline: ContinuousClock.Instant
    fileprivate let owner: UUID
    fileprivate let commands: [ClientMessageID: V2SendMessageCommand]
    fileprivate let snapshot: V2RoomPolicySnapshot

    fileprivate init(runtime: PostgresV2RoomPolicyAuthorization, activation: V2RoomActivationToken,
                     owner: UUID, commands: [ClientMessageID: V2SendMessageCommand],
                     snapshot: V2RoomPolicySnapshot, deadline: ContinuousClock.Instant) {
        self.runtime = runtime; self.activation = activation; self.owner = owner
        self.commands = commands; self.snapshot = snapshot; self.deadline = deadline
    }

    var currentDirectPolicy: V2DirectSendControlPolicy? {
        if case .current(let value) = snapshot { return value.policy }; return nil
    }

    func contains(_ command: V2SendMessageCommand) throws -> Bool {
        guard let original = commands[command.clientMessageID] else { return false }
        guard original == command else { throw V2DirectAuthorizationIntentError.identityConflict }
        return true
    }
}

/// One room direction within one activation. Cold loads coalesce; ordinary
/// sends reuse memory and only hold a room-database lease fence through commit.
actor PostgresV2RoomPolicyAuthorization {
    typealias Loader = @Sendable (UUID, UUID) async throws -> V2RegisteredDirectPolicySnapshot
    typealias RoomLoader = @Sendable (UUID, UUID) async throws -> V2RegisteredRoomPolicySnapshot
    typealias AccountLoader = @Sendable (UUID, UUID) async throws -> V2RegisteredAccountPolicySnapshot
    typealias CurrentLoader = @Sendable () async throws -> V2CurrentRoomPolicySnapshot
    private struct Load {
        let id: UUID
        let task: Task<V2RegisteredRoomPolicySnapshot, any Error>
    }
    private struct Revocation {
        let holder: V2PolicyAuthorizationHolder
        let task: Task<V2PolicyAuthorizationRevocationProof, any Error>
    }
    private let identity = UUID()
    private let activation: V2RoomActivationToken
    nonisolated let activationID = UUID()
    private let pair: V2DirectSendControlPair?
    private let sender: UUID
    private let endpoint: String
    private let loader: RoomLoader
    private let currentLoader: CurrentLoader?
    private let maximumInFlight: Int
    private var currentLoads: [UUID: Task<V2CurrentRoomPolicySnapshot, any Error>] = [:]
    private let fence: PostgresV2RoomPolicyLeaseFence
    private let gate: V2RoomPolicyAuthorizationGate
    private let maximumRevocations: Int
    private var installed: V2RegisteredRoomPolicySnapshot?
    private var load: Load?
    private var executions: [UUID: Task<Void, Never>] = [:]
    private var revocations: [UUID: Revocation] = [:]
    private var preparations = 0
    private var promotions = 0
    private var closed = false

    init(activation: V2RoomActivationToken, pair: V2DirectSendControlPair, endpoint: String,
         fence: PostgresV2RoomPolicyLeaseFence, maximumInFlight: Int = 16,
         maximumRevocations: Int = 16, currentLoader: CurrentLoader? = nil, loader: @escaping Loader) {
        precondition(activation.roomID.uuidValue != nil && pair.sender != pair.recipient)
        precondition(!endpoint.isEmpty && endpoint.utf8.count <= 512 && maximumRevocations > 0)
        self.activation = activation; self.pair = pair; self.sender = pair.sender; self.endpoint = endpoint
        self.fence = fence; self.loader = { .direct(try await loader($0, $1)) }; self.maximumRevocations = maximumRevocations
        self.currentLoader = currentLoader; self.maximumInFlight = maximumInFlight
        gate = .init(activation: activationID, ownerEpoch: activation.owner.epoch, maximumInFlight: maximumInFlight)
    }

    init(activation: V2RoomActivationToken, groupSender: UUID, endpoint: String,
         fence: PostgresV2RoomPolicyLeaseFence, maximumInFlight: Int = 16,
         maximumRevocations: Int = 16, currentLoader: CurrentLoader? = nil, loader: @escaping AccountLoader) {
        precondition(activation.roomID.uuidValue != nil && !endpoint.isEmpty && endpoint.utf8.count <= 512 && maximumRevocations > 0)
        self.activation = activation; self.pair = nil; self.sender = groupSender; self.endpoint = endpoint
        self.fence = fence; self.loader = { .account(try await loader($0, $1)) }; self.maximumRevocations = maximumRevocations
        self.currentLoader = currentLoader; self.maximumInFlight = maximumInFlight
        gate = .init(activation: activationID, ownerEpoch: activation.owner.epoch, maximumInFlight: maximumInFlight)
    }

    func warm() async throws {
        preparations += 1
        defer { preparations -= 1 }
        _ = try await preparationSnapshot(callerDeadline: V2RoomSQLDeadline.boundedTransactionDeadline())
    }

    func execute<Value: Sendable>(command: V2SendMessageCommand, callerDeadline: ContinuousClock.Instant,
        operation: @escaping @Sendable (V2RoomPolicyExecution) async throws -> Value) async throws -> Value {
        try await executeBatch(commands: [command], callerDeadline: callerDeadline, operation: operation)
    }

    /// One actual transaction can own several exact message identities. The
    /// permit drains only when the entire operation (including COMMIT) settles.
    func executeBatch<Value: Sendable>(commands: [V2SendMessageCommand], callerDeadline: ContinuousClock.Instant,
        operation: @escaping @Sendable (V2RoomPolicyExecution) async throws -> Value) async throws -> Value {
        let prepared = try await prepareBatch(commands: commands, callerDeadline: callerDeadline)
        return try await executePreparedBatch(prepared, operation: operation)
    }

    func prepareBatch(commands: [V2SendMessageCommand], callerDeadline: ContinuousClock.Instant,
                      trustedForward: Bool = false) async throws -> V2RoomPolicyPreparation {
        try Task.checkCancellation()
        guard !closed else { throw V2PolicyAuthorizationLifecycleError.closed }
        preparations += 1
        defer { preparations -= 1 }
        guard !commands.isEmpty, commands.count <= 256,
              commands.allSatisfy({ $0.roomID == activation.roomID && $0.senderUserID.uuidValue == sender
                  && ($0.forwardedFrom == nil || trustedForward) && $0.fingerprint.version == 3 }) else {
            throw V2DirectAuthorizationIntentError.identityConflict
        }
        var originals: [ClientMessageID: V2SendMessageCommand] = [:]
        for command in commands {
            if let prior = originals[command.clientMessageID], prior != command {
                throw V2DirectAuthorizationIntentError.identityConflict
            }
            originals[command.clientMessageID] = command
        }
        guard callerDeadline > .now else { throw V2RoomPolicyAuthorizationGate.Failure.expired }
        let snapshot = try await preparationSnapshot(callerDeadline: callerDeadline)
        try Task.checkCancellation()
        guard !closed else { throw V2PolicyAuthorizationLifecycleError.closed }
        let deadline = min(callerDeadline, snapshot.deadline)
        guard deadline > .now else { throw V2RoomPolicyAuthorizationGate.Failure.expired }
        return .init(runtime: self, activation: activation, owner: identity, commands: originals,
            snapshot: snapshot, deadline: deadline)
    }

    /// Promotion never refreshes a queued stale snapshot behind its caller.
    /// A retry must return to preparation before borrowing any SQL connection.
    func executePreparedBatch<Value: Sendable>(_ prepared: V2RoomPolicyPreparation,
        executorPreference: (any TaskExecutor)? = nil,
        operation: @escaping @Sendable (V2RoomPolicyExecution) async throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        guard !closed else { throw V2PolicyAuthorizationLifecycleError.closed }
        guard prepared.owner == identity, prepared.activation == activation else {
            throw V2PolicyAuthorizationLifecycleError.identityConflict
        }
        let snapshot = prepared.snapshot
        promotions += 1
        defer { promotions -= 1 }
        if case .current(let snapshot) = snapshot {
            guard prepared.deadline > .now else { throw V2RoomPolicyAuthorizationGate.Failure.expired }
            guard executions.count < maximumInFlight else { throw V2RoomPolicyAuthorizationGate.Failure.overloaded }
            let lifetime = V2CurrentPolicyExecutionLifetime()
            let execution = V2RoomPolicyExecution(commands: prepared.commands, snapshot: snapshot,
                activation: activation, fence: fence, lifetime: lifetime)
            let id = UUID()
            let task = Task.detached(executorPreference: executorPreference) {
                let result: Result<Value, any Error>
                do { result = .success(try await operation(execution)) } catch { result = .failure(error) }
                await lifetime.settled()
                await self.executionFinished(id)
                return try result.get()
            }
            executions[id] = Task.detached { _ = await task.result }
            return try await task.value
        }
        guard case .registered(let snapshot) = snapshot else { throw V2PolicyAuthorizationLifecycleError.invalidRequest }
        let permit = try await gate.reserveExecution(callerDeadline: prepared.deadline)
        guard !closed, permit.leaseID == snapshot.holder.registrationID, permit.versions == snapshot.versions else {
            try await gate.settled(permit)
            throw V2PolicyAuthorizationLifecycleError.staleVersion
        }
        let execution = V2RoomPolicyExecution(commands: prepared.commands, snapshot: snapshot, activation: activation,
            gate: gate, permit: permit, fence: fence)
        let id = UUID(), gate = gate
        let task = Task.detached(executorPreference: executorPreference) {
            var result: Result<Value, any Error>
            do { result = .success(try await operation(execution)) } catch { result = .failure(error) }
            do { try await gate.settled(permit) } catch { result = .failure(error) }
            await self.executionFinished(id)
            return try result.get()
        }
        executions[id] = Task.detached { _ = await task.result }
        return try await task.value
    }

    func revoke(_ holder: V2PolicyAuthorizationHolder) async throws -> V2PolicyAuthorizationRevocationProof {
        try Task.checkCancellation()
        guard !closed else { throw V2PolicyAuthorizationLifecycleError.closed }
        guard holder.roomID == activation.roomID.uuidValue else { throw V2PolicyAuthorizationLifecycleError.invalidTarget }
        if let existing = revocations[holder.registrationID] {
            guard existing.holder == holder else { throw V2PolicyAuthorizationLifecycleError.identityConflict }
            return try await existing.task.value
        }
        guard revocations.count < maximumRevocations else { throw V2PolicyAuthorizationLifecycleError.busy }
        let gate = gate, fence = fence, current = holder.activationID == activationID && holder.roomOwnerEpoch == activation.owner.epoch
        let task = Task.detached {
            let result: Result<V2PolicyAuthorizationRevocationProof, any Error>
            do {
                if current {
                    try await gate.revoke(lease: .init(id: holder.registrationID, activation: holder.activationID,
                        ownerEpoch: holder.roomOwnerEpoch, generation: holder.generation, validUntil: .now))
                }
                result = .success(try await fence.revoke(holder))
            } catch { result = .failure(error) }
            await self.revocationFinished(holder.registrationID)
            return try result.get()
        }
        revocations[holder.registrationID] = .init(holder: holder, task: task)
        return try await task.value
    }

    /// No suspension between checking real roots and sealing ingress. Queued
    /// preparation witnesses do not pin the cache; promotion rejects a sealed
    /// runtime and must restart preparation on its replacement.
    func sealIfIdle() -> Bool {
        guard preparations == 0, promotions == 0, load == nil, currentLoads.isEmpty,
              executions.isEmpty, revocations.isEmpty else { return false }
        closed = true
        return true
    }

    func shutdown() async throws {
        closed = true
        let loading = load?.task, work = Array(executions.values), retiring = revocations.values.map(\.task)
        let currentLoads = Array(currentLoads.values)
        await gate.shutdown()
        _ = await loading?.result
        for task in currentLoads { _ = await task.result }
        for task in work { await task.value }
        for task in retiring { _ = await task.result }
        if let installed { _ = try await fence.revoke(installed.holder) }
    }

    func pressure() async -> (closed: Bool, loading: Bool, executions: Int, revocations: Int, accepting: Bool) {
        (closed, load != nil || !currentLoads.isEmpty, executions.count, revocations.count,
            currentLoader != nil ? !closed : await gate.snapshot().accepting)
    }

    private func preparationSnapshot(callerDeadline: ContinuousClock.Instant) async throws -> V2RoomPolicySnapshot {
        guard let currentLoader else { return .registered(try await ensureLoaded(callerDeadline: callerDeadline)) }
        guard !closed else { throw V2PolicyAuthorizationLifecycleError.closed }
        let deadline = min(callerDeadline, V2RoomSQLDeadline.boundedTransactionDeadline())
        guard deadline > .now else { throw V2RoomPolicyAuthorizationGate.Failure.expired }
        let id = UUID()
        let trace = V2SendPathTrace.current
        trace?.mark("policy_task_registered")
        let task = Task.detached {
            trace?.mark("policy_task_enter")
            let result: Result<V2CurrentRoomPolicySnapshot, any Error>
            do { result = .success(try await V2SendPathTrace.$current.withValue(trace) {
                try await V2RoomSQLDeadline.withDeadline(deadline) {
                    try await currentLoader()
                }
            }) }
            catch { result = .failure(error) }
            trace?.mark("policy_loader_return")
            await self.currentLoadFinished(id)
            trace?.mark("policy_cleanup_return")
            return try result.get()
        }
        currentLoads[id] = task
        let snapshot = try await task.value
        trace?.mark("policy_waiter_resumed")
        guard !closed else { throw V2PolicyAuthorizationLifecycleError.closed }
        guard snapshot.senderID == sender, snapshot.recipientID == pair?.recipient else {
            throw V2PolicyAuthorizationLifecycleError.identityConflict
        }
        return .current(snapshot)
    }

    private func currentLoadFinished(_ id: UUID) { currentLoads[id] = nil }

    private func ensureLoaded(callerDeadline: ContinuousClock.Instant) async throws -> V2RegisteredRoomPolicySnapshot {
        try Task.checkCancellation()
        guard !closed else { throw V2PolicyAuthorizationLifecycleError.closed }
        let deadline = min(callerDeadline, V2RoomSQLDeadline.boundedTransactionDeadline())
        guard deadline > .now else { throw V2RoomPolicyAuthorizationGate.Failure.expired }
        let state = await gate.snapshot()
        if state.accepting, let installed { return installed }
        if let load { return try await load.task.value }
        guard state.inFlight == 0 else { throw V2RoomPolicyAuthorizationGate.Failure.overloaded }
        let id = UUID(), registration = UUID(), activationID = activationID, loader = loader
        let task = Task.detached {
            let result: Result<V2RegisteredRoomPolicySnapshot, any Error>
            do {
                let snapshot = try await V2RoomSQLDeadline.withDeadline(deadline) {
                    let snapshot = try await loader(registration, activationID)
                    try await self.install(snapshot, registrationID: registration)
                    return snapshot
                }
                result = .success(snapshot)
            } catch { result = .failure(error) }
            await self.loadFinished(id)
            return try result.get()
        }
        load = .init(id: id, task: task)
        return try await task.value
    }

    private func install(_ snapshot: V2RegisteredRoomPolicySnapshot, registrationID: UUID) async throws {
        guard !closed else { throw V2PolicyAuthorizationLifecycleError.closed }
        let holder = snapshot.holder
        guard holder.registrationID == registrationID, holder.roomID == activation.roomID.uuidValue, holder.activationID == activationID,
              holder.roomOwnerEpoch == activation.owner.epoch, holder.endpoint == endpoint,
              snapshot.senderID == sender, snapshot.recipientID == pair?.recipient else {
            throw V2PolicyAuthorizationLifecycleError.identityConflict
        }
        try await fence.install(holder)
        guard !closed else { throw V2PolicyAuthorizationLifecycleError.closed }
        let policy = try snapshot.gatePolicy()
        try await gate.install(policy, lease: .init(id: holder.registrationID, activation: holder.activationID,
            ownerEpoch: holder.roomOwnerEpoch, generation: holder.generation, validUntil: snapshot.deadline))
        guard !closed else { throw V2PolicyAuthorizationLifecycleError.closed }
        installed = snapshot
    }

    private func executionFinished(_ id: UUID) { executions[id] = nil }
    private func revocationFinished(_ id: UUID) { revocations[id] = nil }
    private func loadFinished(_ id: UUID) { if load?.id == id { load = nil } }
}
