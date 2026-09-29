import IMV2ServerApplication
import IMV2ServerContracts
import FluentKit
import Foundation
import IMV2Core
import SQLKit

extension V2ForwardPlanService {
    public init(
        store: PostgresV2ForwardPlanStore,
        port: V2OwnerAwareForwardPlanPort,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.init(store: store as any V2ForwardPlanStoring, port: port, clock: clock)
    }

    public init(
        store: PostgresV2ForwardPlanStore,
        reconcile: @escaping @Sendable (UserID, V2ForwardMessagesCommand, Bool) async throws -> [V2ForwardPlanItemResult]?,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.init(store: store as any V2ForwardPlanStoring, reconcile: reconcile, clock: clock)
    }
}

/// Account metadata only. Room content and acceptance remain owned by RoomRef.
/// A processing child is a durable handoff; recovery never turns it into an unstarted cancellation.
public struct PostgresV2ForwardPlanStore: V2ForwardPlanStoring, Sendable {
    private let database: any Database
    private let clock: @Sendable () -> Date
    public init(database: any Database, clock: @escaping @Sendable () -> Date = Date.init) {
        self.database = database; self.clock = clock
    }
    public func dueCommands(limit:Int=16) async throws -> [V2ForwardPlanOperationCommand] {
        guard (1...64).contains(limit),let sql=database as? any SQLDatabase else { throw V2ForwardPlanValidationError.invalidPlan }
        let rows=try await sql.raw("SELECT command_json::text AS command_json FROM im_v2.forward_plan_operations WHERE resolved_json IS NULL AND next_action_at<=\(bind:clock()) ORDER BY next_action_at,actor_user_id,operation_id LIMIT \(bind:limit)").all(decoding:CommandRow.self)
        return try rows.map { try JSONDecoder().decode(V2ForwardPlanOperationCommand.self,from:Data($0.command_json.utf8)) }
    }
    public func deferNextAction(_ command:V2ForwardPlanOperationCommand) async throws {
        guard let sql=database as? any SQLDatabase else { throw V2ForwardPlanValidationError.invalidProgress }
        try await sql.raw("UPDATE im_v2.forward_plan_operations SET next_action_at=\(bind:clock().addingTimeInterval(2)) WHERE actor_user_id=\(bind:command.actorUserID.uuidValue!) AND operation_id=\(bind:command.operationID.uuidValue!) AND resolved_json IS NULL").run()
    }
    private struct CommandRow:Decodable { let command_json:String }
    public func submit(_ command: V2ForwardPlanOperationCommand) async throws -> V2ForwardPlanRecoveryResult {
        try await locked(command) { [self] sql, existing in
            if let existing { return try result(existing, command: command) }
            let now = try milliseconds(clock())
            let expired = command.firstSubmissionDeadlineMilliseconds <= now || command.firstSubmissionDeadlineMilliseconds - now > 86_400_000
            let progress = try initial(command, cancelled: expired, now: now)
            let resolved = expired ? try terminal(command, progress: progress, outcome: .rejected(.expiredUnsubmitted), now: now) : nil
            try await insert(command, progress: progress, resolved: resolved, sql: sql)
            return resolved.map(V2ForwardPlanRecoveryResult.receipt) ?? .processing(progress)
        }
    }
    public func recover(_ request: V2ForwardPlanRecoveryRequest) async throws -> V2ForwardPlanRecoveryResult {
        let command = request.command
        return try await locked(command) { [self] sql, existing in
            let now = try milliseconds(clock())
            guard let existing else {
                guard request.action != .query else { return .unresolved }
                let progress = try initial(command, cancelled: true, now: now)
                let resolved = try terminal(command, progress: progress, outcome: .closedBeforeStart, now: now)
                try await insert(command, progress: progress, resolved: resolved, sql: sql)
                return .receipt(resolved)
            }
            let prior = try result(existing, command: command)
            guard case .processing(let progress) = prior, request.action != .query else { return prior }
            let started = progress.children.contains { if case .pending = $0.state { return false }; return true }
            guard request.action == .cancelRemaining || !started else { return prior }
            let children = try progress.children.map { child in
                guard case .pending = child.state else { return child }
                return try cancelledChild(command, index: child.index, now: now)
            }
            let allResolved = children.allSatisfy { if case .resolved = $0.state { return true }; return false }
            let next = try V2ForwardPlanProgress(identity: command.identity, fingerprint: command.fingerprint,
                executionState: allResolved ? .completed : .cancelling, children: children)
            let resolved = allResolved ? try terminal(command, progress: next,
                outcome: started ? .completed(.derive(command: command, progress: next)) : .closedBeforeStart, now: now) : nil
            try await update(command, progress: next, resolved: resolved, sql: sql)
            return resolved.map(V2ForwardPlanRecoveryResult.receipt) ?? .processing(next)
        }
    }
    /// The returned frozen child is the only execution payload. Claim and cancellation share the parent lock.
    public func claimNext(_ command: V2ForwardPlanOperationCommand) async throws -> V2ForwardMessagesCommand? {
        try await locked(command) { [self] sql, existing in
            guard let existing, case .processing(let progress) = try result(existing, command: command),
                  progress.executionState != .cancelling else { return nil }
            if progress.executionState == .waitingToStart,
               command.firstSubmissionDeadlineMilliseconds <= (try milliseconds(clock())) {
                let now = try milliseconds(clock())
                let expired = try initial(command, cancelled: true, now: now)
                let resolved = try terminal(command, progress: expired, outcome: .rejected(.expiredUnsubmitted), now: now)
                try await update(command, progress: expired, resolved: resolved, sql: sql)
                return nil
            }
            if let existing=progress.children.first(where:{if case .processing=$0.state { return true };return false}) {
                return try command.childCommand(index:existing.index)
            }
            guard let child = progress.children.first(where: { if case .pending = $0.state { return true }; return false }) else { return nil }
            let children = try progress.children.map { value in
                value.index == child.index ? try V2ForwardPlanChildProgress(index: value.index, operationID: value.operationID, state: .processing) : value
            }
            let next = try V2ForwardPlanProgress(identity: command.identity, fingerprint: command.fingerprint, executionState: .processing, children: children)
            try await update(command, progress: next, resolved: nil, sql: sql)
            return try command.childCommand(index: child.index)
        }
    }
    /// Call only with a receipt obtained from the child owner authority, never current visibility failures.
    public func record(_ child: V2ForwardPlanChildReceipt, command: V2ForwardPlanOperationCommand) async throws -> V2ForwardPlanRecoveryResult {
        guard child.validates(command: command), case .completed = child.outcome else { throw V2ForwardPlanValidationError.invalidReceipt }
        return try await locked(command) { [self] sql, existing in
            guard let existing else { throw V2ForwardPlanValidationError.invalidProgress }
            let prior = try result(existing, command: command)
            guard case .processing(let progress) = prior else { return prior }
            if case .resolved(let old) = progress.children[Int(child.index)].state {
                guard old.outcome == child.outcome else { throw V2ForwardPlanValidationError.invalidReceipt }; return prior
            }
            guard case .processing = progress.children[Int(child.index)].state else { throw V2ForwardPlanValidationError.invalidProgress }
            let children = try progress.children.map { value in value.index == child.index ? try .init(index: value.index, operationID: value.operationID, state: .resolved(child)) : value }
            let complete = children.allSatisfy { if case .resolved = $0.state { return true }; return false }
            let next = try V2ForwardPlanProgress(identity: command.identity, fingerprint: command.fingerprint, executionState: complete ? .completed : progress.executionState, children: children)
            guard next.canAdvance(from: progress, command: command) else { throw V2ForwardPlanValidationError.invalidProgress }
            let resolved = complete ? try terminal(command, progress: next, outcome: .completed(.derive(command: command, progress: next)), now: milliseconds(clock())) : nil
            try await update(command, progress: next, resolved: resolved, sql: sql)
            return resolved.map(V2ForwardPlanRecoveryResult.receipt) ?? .processing(next)
        }
    }
    private func locked<T: Sendable>(_ command: V2ForwardPlanOperationCommand,
        operation: @escaping @Sendable (any SQLDatabase, Row?) async throws -> T) async throws -> T {
        try await v2WithPostgresTransactionRetry(database: database, maximumRetryCount: 0) { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2ForwardPlanValidationError.invalidProgress }
            let identity = try command.identity
            try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: "forward-plan:" + identity.storageKey),0))").run()
            let row = try await sql.raw("SELECT command_json::text,progress_json::text,resolved_json::text FROM im_v2.forward_plan_operations WHERE actor_user_id=\(bind: command.actorUserID.uuidValue!) AND operation_id=\(bind: command.operationID.uuidValue!) FOR UPDATE").first(decoding: Row.self)
            return try await operation(sql, row)
        }
    }
    private struct Row: Decodable, Sendable {
        let command_json: String; let progress_json: String; let resolved_json: String?
    }
    private func result(_ row: Row, command: V2ForwardPlanOperationCommand) throws -> V2ForwardPlanRecoveryResult {
        let saved = try JSONDecoder().decode(V2ForwardPlanOperationCommand.self, from: Data(row.command_json.utf8))
        guard try saved.fingerprint == command.fingerprint, try saved.identity == command.identity else { return .fingerprintConflict }
        if let json = row.resolved_json {
            let resolved = try JSONDecoder().decode(V2ForwardPlanResolvedResult.self, from: Data(json.utf8))
            guard resolved.validates(command: command) else { throw V2ForwardPlanValidationError.invalidReceipt }; return .receipt(resolved)
        }
        let progress = try JSONDecoder().decode(V2ForwardPlanProgress.self, from: Data(row.progress_json.utf8))
        guard progress.validates(command: command) else { throw V2ForwardPlanValidationError.invalidProgress }; return .processing(progress)
    }
    private func initial(_ command: V2ForwardPlanOperationCommand, cancelled: Bool, now: UInt64) throws -> V2ForwardPlanProgress {
        let children = try (0..<command.childCount).map { index in
            cancelled ? try cancelledChild(command, index: index, now: now) : try .init(index: index, operationID: command.childCommand(index: index).operationID, state: .pending)
        }
        return try .init(identity: command.identity, fingerprint: command.fingerprint, executionState: cancelled ? .completed : .waitingToStart, children: children)
    }
    private func cancelledChild(_ command: V2ForwardPlanOperationCommand, index: UInt64, now: UInt64) throws -> V2ForwardPlanChildProgress {
        let child = try V2ForwardPlanChildReceipt(parentIdentity: command.identity, parentFingerprint: command.fingerprint, index: index, operationID: command.childCommand(index: index).operationID, outcome: .cancelledBeforeStart, resolvedAtMilliseconds: now)
        return try .init(index: index, operationID: child.operationID, state: .resolved(child))
    }
    private func terminal(_ command: V2ForwardPlanOperationCommand, progress: V2ForwardPlanProgress, outcome: V2ForwardPlanTerminalOutcome, now: UInt64) throws -> V2ForwardPlanResolvedResult {
        try .init(receipt: .init(identity: command.identity, fingerprint: command.fingerprint, outcome: outcome, resolvedAtMilliseconds: now), progress: progress)
    }
    private func insert(_ command: V2ForwardPlanOperationCommand, progress: V2ForwardPlanProgress, resolved: V2ForwardPlanResolvedResult?, sql: any SQLDatabase) async throws {
        if resolved == nil {
            try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: "forward-plan-admission:" + command.actorUserID.rawValue),0))").run()
            guard let count = try await sql.raw("SELECT count(*)::bigint AS count FROM im_v2.forward_plan_operations WHERE actor_user_id=\(bind: command.actorUserID.uuidValue!) AND resolved_json IS NULL").first(decoding: Count.self), count.count < 64 else {
                throw V2ForwardPlanStoreError.admissionUnavailable
            }
        }
        try await sql.raw("INSERT INTO im_v2.forward_plan_operations(next_action_at,actor_user_id,operation_id,command_json,progress_json,resolved_json) VALUES(\(bind: clock()),\(bind: command.actorUserID.uuidValue!),\(bind: command.operationID.uuidValue!),\(bind: json(command))::jsonb,\(bind: json(progress))::jsonb,\(bind: resolved.map { try json($0) })::jsonb)").run()
    }
    private struct Count: Decodable { let count: Int64 }
    private func update(_ command: V2ForwardPlanOperationCommand, progress: V2ForwardPlanProgress, resolved: V2ForwardPlanResolvedResult?, sql: any SQLDatabase) async throws {
        try await sql.raw("UPDATE im_v2.forward_plan_operations SET progress_json=\(bind: json(progress))::jsonb,resolved_json=\(bind: resolved.map { try json($0) })::jsonb WHERE actor_user_id=\(bind: command.actorUserID.uuidValue!) AND operation_id=\(bind: command.operationID.uuidValue!) AND resolved_json IS NULL").run()
    }
    private func json<T: Encodable>(_ value: T) throws -> String { String(decoding: try JSONEncoder().encode(value), as: UTF8.self) }
    private func milliseconds(_ value: Date) throws -> UInt64 {
        let ms = value.timeIntervalSince1970 * 1000
        guard ms.isFinite, ms > 0, ms < Double(Int64.max) else { throw V2ForwardPlanValidationError.invalidReceipt }
        return UInt64(ms)
    }
}
