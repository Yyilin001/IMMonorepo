import IMV2ServerApplication
import IMV2ServerContracts
import FluentKit
import IMV2ActorContracts
import IMV2Core
import SQLKit
import Foundation

/// 在单个物理所有者数据库上执行已获准的房间读取。
/// 实时拉取在单条数据库快照中校验 activation 与成员可见性；
/// 其他查询沿用事务围栏。宿主缓存的就绪状态不是权限依据。
public struct V2ActorRoomQueryExecutor: Sendable {
    private let database: any Database
    private let timeouts: V2RoomActivationSQLTimeouts

    public init(database: any Database, timeouts: V2RoomActivationSQLTimeouts = .default) {
        self.database = database
        self.timeouts = timeouts
    }

    public func log(_ query: V2RoomLogQuery, token: V2RoomActivationToken) async throws -> V2RoomLogQueryResult {
        switch query {
        case .pull(let request): return try await pullSnapshot(request, token: token)
        case .subscribe(let request):
            return try await withFencedRead(roomIDs: [query.roomID], tokens: [token], source: .groupEventSubscribe) { transaction in
                let subscription = try await PostgresV2GroupEventLogStore(database: transaction)
                    .subscribe(roomID: request.roomID, actorUserID: request.actorUserID)
                return .subscription(try .init(subscription))
            }
        }
    }

    /// Pure authorized snapshot: does not serialize behind uncommitted room
    /// commands, but validates the full activation and viewer in PostgreSQL.
    public func pullSnapshot(_ request: V2ActorRoomLogPullWire, token: V2RoomActivationToken) async throws -> V2RoomLogQueryResult {
        guard request.roomID == token.roomID else { throw V2RoomActivationLeaseError.activationChanged }
        let id = UUID()
        let item = V2GrantedRoomLogPull(id: id, token: token, query: request,
            callDeadline: V2RoomSQLDeadline.current ?? .now.advanced(by: .seconds(10)))
        let observed = (database as? V2EventLoopBalancedDatabase)?.usingObservationSource(.groupEventPull) ?? database
        let result = try await v2WithOwnerBatchConnection(database: observed, deadline: item.callDeadline,
            metrics: nil, interrupted: { _ in }) { borrowed, _ in
            try await self.pullSubgroup([item], database: borrowed, maximumResponseBytes: 4_194_304)
        }
        guard let value = result.results[id] else { throw V2RoomRecoveryReadError.corruptPersistence }
        let response = try value.get()
        if case .failure(let reason) = response {
            switch reason {
            case .invalidRequest: throw V2GroupEventLogError.invalidRequest
            case .roomNotFound: throw V2GroupEventLogError.roomNotFound
            case .actorNotMember: throw V2GroupEventLogError.actorNotMember
            case .corruptPersistenceState: throw V2GroupEventLogError.corruptPersistenceState
            }
        }
        return response
    }

    /// Each subgroup finishes its statement snapshot before callbacks. The borrowed physical loan
    /// and collector's actual slot remain owned across all sequential groups.
    package func pullSnapshots(_ items: [V2GrantedRoomLogPull], maximumResponseBytes: Int,
        onSettled: @escaping @Sendable (UUID, Result<V2RoomLogQueryResult, any Error>) async -> Void
    ) async throws {
        guard !items.isEmpty, items.count <= 100, Set(items.map(\.id)).count == items.count,
              maximumResponseBytes > 0 else { throw V2HostRoomRecoveryBatchError.corruptResult }
        let originalDeadline = items.map(\.callDeadline).min()!
        let deadline = V2RoomSQLDeadline.current.map { min($0, originalDeadline) } ?? originalDeadline
        let metrics = V2RoomSQLContinuationObservation.metrics
        let observed = (database as? V2EventLoopBalancedDatabase)?.usingObservationSource(.groupEventPull) ?? database
        // Capture the absolute deadline and recorder before NIO creates a task;
        // future.get cancellation never releases the real connection early.
        try await v2WithOwnerBatchConnection(database: observed, deadline: deadline,
            metrics: nil, interrupted: { _ in }) { borrowed, isUsable in
            try await V2RoomSQLDeadline.withSelectedDeadline(deadline) {
                try await V2RoomSQLContinuationObservation.$metrics.withValue(metrics) {
                    var remaining = items
                    // Fixed scalar packing hints only: no authority, cursor
                    // result, event IDs or payloads survive a statement.
                    var byteHints: [UUID: Int] = [:]
                    while !remaining.isEmpty {
                        guard ContinuousClock.now < deadline, isUsable() else { throw V2HostRoomRecoveryBatchError.deadlineExceeded }
                        let selected = try Self.selectPullInputs(remaining, byteHints: byteHints,
                            maximumResponseBytes: maximumResponseBytes)
                        let batch = try await self.pullSubgroup(selected, database: borrowed,
                            maximumResponseBytes: maximumResponseBytes)
                        byteHints.merge(batch.byteHints) { _, fresh in fresh }
                        guard !batch.results.isEmpty,
                              Set(batch.results.keys).isSubset(of: Set(remaining.map(\.id))) else {
                            throw V2HostRoomRecoveryBatchError.corruptResult
                        }
                        // No pages survive the next iteration; the complete
                        // statement snapshot precedes every callback.
                        for item in remaining {
                            guard var result = batch.results[item.id] else { continue }
                            if item.callDeadline <= .now, case .success = result {
                                result = .failure(V2HostRoomRecoveryBatchError.deadlineExceeded)
                            }
                            await onSettled(item.id, result)
                        }
                        let done = Set(batch.results.keys)
                        remaining.removeAll { done.contains($0.id) }
                        for id in done { byteHints.removeValue(forKey: id) }
                    }
                }
            }
        }
    }

    private struct PullSubgroup: Sendable {
        let results: [UUID: Result<V2RoomLogQueryResult, any Error>]
        var byteHints: [UUID: Int] = [:]
    }

    private static func selectPullInputs(_ remaining: [V2GrantedRoomLogPull],
        byteHints: [UUID: Int], maximumResponseBytes: Int
    ) throws -> [V2GrantedRoomLogPull] {
        // A retired token and its successor never share one authority result.
        var tokens: [RoomID: V2RoomActivationToken] = [:]
        let coherent = remaining.filter { item in
            if let selected = tokens[item.token.roomID] { return selected == item.token }
            tokens[item.token.roomID] = item.token
            return true
        }
        let unknown = coherent.filter { byteHints[$0.id] == nil }
        // Initial discovery computes pages and bounds in one statement. Later
        // subgroups use only scalar size hints; authority is always re-read.
        if !unknown.isEmpty { return unknown }
        var selected: [V2GrantedRoomLogPull] = [], bytes = 2
        for item in coherent {
            guard let upper = byteHints[item.id], upper >= 0 else { throw V2HostRoomRecoveryBatchError.corruptResult }
            let additional = upper.addingReportingOverflow(1)
            let next = bytes.addingReportingOverflow(additional.partialValue)
            guard !additional.overflow, !next.overflow else { throw V2HostRoomRecoveryBatchError.corruptResult }
            if next.partialValue <= maximumResponseBytes {
                selected.append(item); bytes = next.partialValue
            } else if selected.isEmpty {
                // A conservative singleton estimate is not a public rejection.
                return [item]
            }
        }
        guard !selected.isEmpty else { throw V2HostRoomRecoveryBatchError.corruptResult }
        return selected
    }

    private func pullSubgroup(_ items: [V2GrantedRoomLogPull], database: any Database,
        maximumResponseBytes: Int
    ) async throws -> PullSubgroup {
        if timeouts != .default {
            return try await v2WithRoomScopedTransaction(database: database, timeouts: timeouts) { scoped in
                try await self.pullSubgroupSnapshot(items, database: scoped, maximumResponseBytes: maximumResponseBytes)
            }
        }
        return try await pullSubgroupSnapshot(items, database: database, maximumResponseBytes: maximumResponseBytes)
    }

    private func pullSubgroupSnapshot(_ items: [V2GrantedRoomLogPull], database: any Database,
        maximumResponseBytes: Int
    ) async throws -> PullSubgroup {
        guard let sql = database as? any SQLDatabase else { throw V2RoomRecoveryReadError.corruptPersistence }
        (database as? any V2ObservedDatabaseHandle)?.loanObservation?.setSQLPhase(.readBody)
        var tokens: [RoomID: V2RoomActivationToken] = [:]
        var results: [UUID: Result<V2RoomLogQueryResult, any Error>] = [:], input: [V2GroupEventPullBatchInput] = []
        for (ordinal, item) in items.enumerated() {
            guard item.query.roomID == item.token.roomID,
                  tokens[item.token.roomID].map({ $0 == item.token }) ?? true else {
                throw V2RoomActivationLeaseError.activationChanged
            }
            tokens[item.token.roomID] = item.token
            do { input.append(try .init(ordinal: ordinal, query: item.query)) }
            catch let error as V2GroupEventLogError { results[item.id] = .success(.failure(.init(error))) }
        }
        guard !input.isEmpty else { return PullSubgroup(results: results) }
        let packed = try await v2PackedGroupEventPulls(input, tokens: tokens,
            maximumBytes: maximumResponseBytes, sql: sql)
        var hints: [UUID: Int] = [:]
        for value in input {
            let item = items[value.ordinal]
            hints[item.id] = packed.byteHints[value.ordinal]
            guard packed.selected.contains(value.ordinal) else { continue }
            if let error = packed.failures[value.ordinal] { results[item.id] = .failure(error); continue }
            guard let facts = packed.metadata[value.ordinal] else { throw V2RoomRecoveryReadError.corruptPersistence }
            do {
                try facts.validate()
                let page = try v2DecodeGroupEventPull(packed.rows[value.ordinal] ?? [],
                    roomID: item.query.roomID, afterRoomSequence: item.query.afterRoomSequence)
                guard page.events.count == Int(facts.eventCount),
                      page.nextRoomSequence == max(item.query.afterRoomSequence, UInt64(facts.scannedThrough!)),
                      page.hasMore == facts.hasMore!,
                      page.logTrimmedThroughRoomSequence == UInt64(facts.trimmedThrough!) else {
                    throw V2GroupEventLogError.corruptPersistenceState
                }
                let wire = try V2ActorRoomLogPageWire(page)
                guard try wire.protobufResponseByteCount() + 64 <= hints[item.id]! else {
                    throw V2GroupEventLogError.corruptPersistenceState
                }
                results[item.id] = .success(.page(wire))
            } catch let error as V2GroupEventLogError { results[item.id] = .success(.failure(.init(error))) }
        }
        if results.isEmpty, let value = input.first {
            let item = items[value.ordinal]
            if let failure = packed.failures[value.ordinal] { results[item.id] = .failure(failure) }
            else {
                // A conservative batching bound cannot reject a legal native
                // singleton page. Repeat with its independent scalar budget.
                let scalar = try await pullSubgroupSnapshot([item], database: database, maximumResponseBytes: Int.max / 4)
                return .init(results: scalar.results, byteHints: hints)
            }
        }
        return .init(results: results, byteHints: hints)
    }

    public func directory(_ query: V2RoomDirectoryQuery, token: V2RoomActivationToken) async throws -> V2RoomDirectoryResult {
        try await withFencedRead(roomIDs: [query.roomID], tokens: [token]) { transaction in
            switch query {
            case .membership(let wire):
                do {
                    let page = try await PostgresV2RoomMembershipDirectoryStore(database: transaction)
                        .list(wire.domainValue())
                    return .membership(.init(page))
                } catch let error as V2RoomMembershipDirectoryError {
                    return .membershipFailure(.init(error))
                }
            case .roleBaseline(let wire):
                do {
                    let baseline = try await PostgresV2GroupRolePolicyBaselineStore(database: transaction)
                        .readRolePolicyBaseline(roomID: wire.roomID, actorUserID: wire.actorUserID)
                    return .roleBaseline(.init(baseline))
                } catch let error as V2GroupRolePolicyBaselineError {
                    return .roleBaselineFailure(.init(error))
                }
            }
        }
    }

    /// `tokens` 必须与查询的精确房间集合一致。
    /// 随后既有恢复存储只执行一条集合 SQL 语句，而非每房间一次调用。
    public func recovery(_ query: V2RoomRecoveryQuery, tokens: [V2RoomActivationToken]) async throws -> V2RoomRecoveryResult {
        try await withFencedRead(roomIDs: query.roomIDs, tokens: tokens, source: .roomRecovery) { transaction in
            do {
                switch query {
                case .states(let wire):
                    let values = try await PostgresV2RoomRecoveryStore(database: transaction)
                        .states(roomIDs: wire.roomIDs, actorUserID: wire.actorUserID)
                    return .states(try .init(values, requestedRoomIDs: wire.roomIDs))
                case .latestVisible(let wire):
                    let values = try await PostgresV2RoomLatestVisibleStore(database: transaction)
                        .latestVisible(roomIDs: wire.roomIDs, actorUserID: wire.actorUserID)
                    return .latestVisible(try .init(values, requestedRoomIDs: wire.roomIDs))
                }
            } catch let error as V2RoomRecoveryReadError {
                return .failure(.init(error))
            }
        }
    }

    /// Only Host-admitted turns reach this physical-owner collection point.
    /// No viewer result is keyed by room alone, and no in-flight SQL is split
    /// into per-room retries after an infrastructure failure.
    public func recoveryStates(_ turns: [V2GrantedRoomReadTurn], schema: String = "im_v2") async throws
        -> [V2RoomStateReadKey: Result<V2RoomStateReadResult, any Error>] {
        guard !turns.isEmpty, turns.count <= 100 else { throw V2RoomRecoveryReadError.invalidRequest }
        var tokens: [RoomID: V2RoomActivationToken] = [:]
        var keys: [V2RoomStateReadKey] = []
        var seen: Set<V2RoomStateReadKey> = []
        for turn in turns {
            if let old = tokens[turn.token.roomID], old != turn.token { throw V2RoomActivationLeaseError.activationChanged }
            tokens[turn.token.roomID] = turn.token
            let key = V2RoomStateReadKey(roomID: turn.token.roomID, viewerUserID: turn.actorUserID)
            if seen.insert(key).inserted { keys.append(key) }
        }
        let selectedKeys = keys, selectedTokens = Array(tokens.values)
        let observed = (database as? V2EventLoopBalancedDatabase)?.usingObservationSource(.roomRecovery) ?? database
        let attempt = V2RoomTransactionAttempt()
        return try await v2WithRoomScopedTransaction(database: observed, timeouts: timeouts) { transaction in
            try await attempt.body {
                guard let sql = transaction as? any SQLDatabase else { throw V2RoomRecoveryReadError.corruptPersistence }
                let observation = (transaction as? any V2ObservedDatabaseHandle)?.loanObservation
                observation?.setSQLPhase(.fence)
                let fenced = try await v2RoomSnapshotReadActivationFences(tokens: selectedTokens, sql: sql,
                    schema: schema, timeouts: timeouts)
                var result: [V2RoomStateReadKey: Result<V2RoomStateReadResult, any Error>] = [:]
                var healthy: [V2RoomStateReadKey] = []
                for key in selectedKeys {
                    guard let outcome = fenced[key.roomID] else { throw V2RoomRecoveryReadError.corruptPersistence }
                    switch outcome {
                    case .success: healthy.append(key)
                    case .failure(let error): result[key] = .failure(error)
                    }
                }
                if !healthy.isEmpty {
                    observation?.setSQLPhase(.readBody)
                    let values = try await PostgresV2RoomRecoveryStore(database: transaction, schema: schema).states(keys: healthy)
                    for key in healthy {
                        guard let value = values[key] else { throw V2RoomRecoveryReadError.corruptPersistence }
                        result[key] = .success(value)
                    }
                }
                guard result.count == selectedKeys.count else { throw V2RoomRecoveryReadError.corruptPersistence }
                return result
            }
        }
    }

    func withFencedRead<Value: Sendable>(
        roomIDs: [RoomID], tokens: [V2RoomActivationToken], source: V2DatabaseLoanSource = .query,
        _ operation: @escaping @Sendable (any Database) async throws -> Value
    ) async throws -> Value {
        guard !roomIDs.isEmpty, roomIDs.count <= 100,
              roomIDs.count == tokens.count,
              Set(roomIDs).count == roomIDs.count,
              Set(tokens.map(\.roomID)) == Set(roomIDs) else {
            throw V2RoomActivationLeaseError.activationChanged
        }
        let attempt = V2RoomTransactionAttempt()
        do {
            let observed = (database as? V2EventLoopBalancedDatabase)?.usingObservationSource(source) ?? database
            return try await v2WithRoomScopedTransaction(database: observed, timeouts: timeouts) { transaction in
                try await attempt.body {
                    guard let sql = transaction as? any SQLDatabase else {
                        throw V2RoomRecoveryReadError.corruptPersistence
                    }
                    let observation = (transaction as? any V2ObservedDatabaseHandle)?.loanObservation
                    observation?.setSQLPhase(.fence)
                    try await v2RequireRoomActivations(tokens: tokens, sql: sql, timeouts: timeouts)
                    observation?.setSQLPhase(.readBody)
                    return try await operation(transaction)
                }
            }
        } catch {
            throw error
        }
    }
}
