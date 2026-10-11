import Foundation
import FluentKit
import IMV2ActorContracts
import IMV2Core
import IMV2ServerApplication
import IMV2ServerContracts
import SQLKit

enum V2RoomPolicyExecutionFailure: Error, Equatable, Sendable {
    case invalidPermit, expired, overloaded
}

fileprivate actor V2CurrentPolicyExecutionLifetime {
    private var active = true
    func requireActive() throws {
        guard active else { throw V2RoomPolicyExecutionFailure.invalidPermit }
    }
    func settled() { active = false }
}

/// Opaque command-bound ownership. The room writer still checks activation,
/// membership, reply markers, special-account rules and quota in its transaction.
struct V2RoomPolicyExecution: Sendable {
    private let commands: [ClientMessageID: V2SendMessageCommand]
    let snapshot: V2CurrentRoomPolicySnapshot
    let activation: V2RoomActivationToken
    private let lifetime: V2CurrentPolicyExecutionLifetime

    fileprivate init(commands: [ClientMessageID: V2SendMessageCommand], snapshot: V2CurrentRoomPolicySnapshot,
                     activation: V2RoomActivationToken, lifetime: V2CurrentPolicyExecutionLifetime) {
        self.commands = commands; self.snapshot = snapshot; self.activation = activation
        self.lifetime = lifetime
    }

    private func requireExecuting() async throws { try await lifetime.requireActive() }

    func validate(_ command: V2SendMessageCommand) throws {
        guard let original = commands[command.clientMessageID], command == original,
              command.fingerprint.version == 3 else {
            throw V2PolicyAuthorizationLifecycleError.identityConflict
        }
    }

    func requireActive(roomID: UUID, senderID: UUID, clientMessageID: UUID, sql: any SQLDatabase) async throws {
        guard let command = commands[.init(uuid: clientMessageID)],
              command.roomID.uuidValue == roomID, command.senderUserID.uuidValue == senderID,
              sql is any Database else {
            throw V2PolicyAuthorizationLifecycleError.identityConflict
        }
        try await requireExecuting()

    }

    static func requireActive(_ inputs: [(execution: Self, command: V2SendMessageCommand)], sql: any SQLDatabase) async throws {
        guard !inputs.isEmpty, inputs.count <= 256, sql is any Database else {
            throw V2PolicyAuthorizationLifecycleError.invalidRequest
        }
        for input in inputs {
            try input.execution.validate(input.command)
            try await input.execution.requireExecuting()
        }
    }

    static func validateActive(_ inputs: [(execution: Self, command: V2SendMessageCommand)]) async throws {
        guard inputs.count <= 256 else { throw V2PolicyAuthorizationLifecycleError.invalidRequest }
        for input in inputs {
            try input.execution.validate(input.command)
            try await input.execution.requireExecuting()
        }
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
    fileprivate let snapshot: V2CurrentRoomPolicySnapshot

    fileprivate init(runtime: PostgresV2RoomPolicyAuthorization, activation: V2RoomActivationToken,
                     owner: UUID, commands: [ClientMessageID: V2SendMessageCommand],
                     snapshot: V2CurrentRoomPolicySnapshot, deadline: ContinuousClock.Instant) {
        self.runtime = runtime; self.activation = activation; self.owner = owner
        self.commands = commands; self.snapshot = snapshot; self.deadline = deadline
    }

    var currentDirectPolicy: V2DirectSendControlPolicy? {
        snapshot.policy
    }

    func contains(_ command: V2SendMessageCommand) throws -> Bool {
        guard let original = commands[command.clientMessageID] else { return false }
        guard original == command else { throw V2PolicyAuthorizationLifecycleError.identityConflict }
        return true
    }
}

/// One room direction within one activation. Each preparation samples current
/// facts; the runtime joins real loading and execution through transaction commit.
actor PostgresV2RoomPolicyAuthorization {
    typealias CurrentLoader = @Sendable () async throws -> V2CurrentRoomPolicySnapshot
    private let identity = UUID()
    private let activation: V2RoomActivationToken
    private let sender: UUID
    private let recipient: UUID?
    private let currentLoader: CurrentLoader
    private let maximumInFlight: Int
    private var currentLoads: [UUID: Task<V2CurrentRoomPolicySnapshot, any Error>] = [:]
    private var executions: [UUID: Task<Void, Never>] = [:]
    private var preparations = 0
    private var promotions = 0
    private var closed = false

    init(activation: V2RoomActivationToken, sender: UUID, recipient: UUID?, maximumInFlight: Int = 16,
         currentLoader: @escaping CurrentLoader) {
        precondition(activation.roomID.uuidValue != nil && sender != recipient && maximumInFlight > 0)
        self.activation = activation; self.sender = sender; self.recipient = recipient
        self.currentLoader = currentLoader; self.maximumInFlight = maximumInFlight
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
            throw V2PolicyAuthorizationLifecycleError.identityConflict
        }
        var originals: [ClientMessageID: V2SendMessageCommand] = [:]
        for command in commands {
            if let prior = originals[command.clientMessageID], prior != command {
                throw V2PolicyAuthorizationLifecycleError.identityConflict
            }
            originals[command.clientMessageID] = command
        }
        guard callerDeadline > .now else { throw V2RoomPolicyExecutionFailure.expired }
        let snapshot = try await preparationSnapshot(callerDeadline: callerDeadline)
        try Task.checkCancellation()
        guard !closed else { throw V2PolicyAuthorizationLifecycleError.closed }
        let deadline = min(callerDeadline, snapshot.deadline)
        guard deadline > .now else { throw V2RoomPolicyExecutionFailure.expired }
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
        let deadline = min(prepared.deadline, V2RoomSQLDeadline.current ?? prepared.deadline)
        guard deadline > .now else { throw V2RoomPolicyExecutionFailure.expired }
        guard executions.count < maximumInFlight else { throw V2RoomPolicyExecutionFailure.overloaded }
        let lifetime = V2CurrentPolicyExecutionLifetime()
        let execution = V2RoomPolicyExecution(commands: prepared.commands, snapshot: snapshot,
            activation: activation, lifetime: lifetime)
        let id = UUID()
        let task = Task.detached(executorPreference: executorPreference) {
            let result: Result<Value, any Error>
            do {
                result = .success(try await V2RoomSQLDeadline.withDeadline(deadline) {
                    try await operation(execution)
                })
            } catch { result = .failure(error) }
            await lifetime.settled()
            await self.executionFinished(id)
            return try result.get()
        }
        executions[id] = Task.detached { _ = await task.result }
        return try await task.value
    }

    /// No suspension between checking real roots and sealing ingress. Queued
    /// preparation witnesses do not pin the cache; promotion rejects a sealed
    /// runtime and must restart preparation on its replacement.
    func sealIfIdle() -> Bool {
        guard preparations == 0, promotions == 0, currentLoads.isEmpty,
              executions.isEmpty else { return false }
        closed = true
        return true
    }

    func shutdown() async {
        closed = true
        let loading = Array(currentLoads.values), work = Array(executions.values)
        for task in loading { _ = await task.result }
        for task in work { await task.value }
    }

    func pressure() -> (closed: Bool, loading: Bool, executions: Int, accepting: Bool) {
        (closed, !currentLoads.isEmpty, executions.count, !closed)
    }

    private func preparationSnapshot(callerDeadline: ContinuousClock.Instant) async throws -> V2CurrentRoomPolicySnapshot {
        guard !closed else { throw V2PolicyAuthorizationLifecycleError.closed }
        let deadline = min(callerDeadline, V2RoomSQLDeadline.boundedTransactionDeadline())
        guard deadline > .now else { throw V2RoomPolicyExecutionFailure.expired }
        let id = UUID()
        let currentLoader = currentLoader
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
        guard snapshot.senderID == sender, snapshot.recipientID == recipient else {
            throw V2PolicyAuthorizationLifecycleError.identityConflict
        }
        return snapshot
    }

    private func currentLoadFinished(_ id: UUID) { currentLoads[id] = nil }

    private func executionFinished(_ id: UUID) { executions[id] = nil }
}
