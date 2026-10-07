import IMV2ServerApplication
import IMV2ServerContracts
import FluentKit
import IMV2ActorContracts
import IMV2Core
import SQLKit
import Foundation

/// 在单个物理所有者数据库上执行已获准的房间读取。
/// 授权会在与权威查询相同的事务中、数据库围栏下再次校验；
/// 宿主缓存的就绪状态不是权限依据。
public struct V2ActorRoomQueryExecutor: Sendable {
    private let database: any Database
    private let timeouts: V2RoomActivationSQLTimeouts

    public init(database: any Database, timeouts: V2RoomActivationSQLTimeouts = .default) {
        self.database = database
        self.timeouts = timeouts
    }

    public func log(_ query: V2RoomLogQuery, token: V2RoomActivationToken) async throws -> V2RoomLogQueryResult {
        let source: V2DatabaseLoanSource
        switch query { case .pull: source = .groupEventPull; case .subscribe: source = .groupEventSubscribe }
        return try await withFencedRead(roomIDs: [query.roomID], tokens: [token], source: source) { transaction in
            // 有意不使用可选的进程事件缓存。持久化成员关系与游标查询
            // 才是此轮读取的权威依据。
            let store = PostgresV2GroupEventLogStore(database: transaction)
            switch query {
            case .pull(let request):
                let page = try await store.pull(roomID: request.roomID,
                    actorUserID: request.actorUserID, afterRoomSequence: request.afterRoomSequence,
                    pageSize: request.pageSize)
                return .page(try .init(page))
            case .subscribe(let request):
                let subscription = try await store.subscribe(roomID: request.roomID,
                    actorUserID: request.actorUserID)
                return .subscription(try .init(subscription))
            }
        }
    }

    /// Pure authorized snapshot: does not serialize behind uncommitted room
    /// commands, but validates the full activation and viewer in PostgreSQL.
    public func pullSnapshot(_ request: V2ActorRoomLogPullWire, token: V2RoomActivationToken) async throws -> V2RoomLogQueryResult {
        guard request.roomID == token.roomID else { throw V2RoomActivationLeaseError.activationChanged }
        let observed = (database as? V2EventLoopBalancedDatabase)?.usingObservationSource(.groupEventPull) ?? database
        let attempt = V2RoomTransactionAttempt()
        return try await v2WithRoomScopedTransaction(database: observed, timeouts: timeouts) { transaction in
            try await attempt.body {
                guard let sql = transaction as? any SQLDatabase else { throw V2RoomRecoveryReadError.corruptPersistence }
                let observation = (transaction as? any V2ObservedDatabaseHandle)?.loanObservation
                observation?.setSQLPhase(.fence)
                let fences = try await v2RoomSnapshotReadActivationFences(tokens: [token], sql: sql,
                    timeouts: timeouts)
                guard let fenced = fences[token.roomID] else { throw V2RoomActivationLeaseError.activationChanged }
                try fenced.get()
                observation?.setSQLPhase(.readBody)
                let page = try await PostgresV2GroupEventLogStore(database: transaction)
                    .pull(roomID: request.roomID, actorUserID: request.actorUserID,
                          afterRoomSequence: request.afterRoomSequence, pageSize: request.pageSize)
                return .page(try .init(page))
            }
        }
    }

    /// Each subgroup commits before its callbacks. The borrowed physical loan
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
        try await observed.withConnection { borrowed in
            borrowed.eventLoop.makeFutureWithTask {
                try await V2RoomSQLDeadline.withSelectedDeadline(deadline) {
                    try await V2RoomSQLContinuationObservation.$metrics.withValue(metrics) {
                        var remaining = items
                        // Fixed scalar packing hints only: no authority, cursor
                        // result, event IDs or payloads survive a COMMIT.
                        var byteHints: [UUID: Int] = [:]
                        while !remaining.isEmpty {
                            guard ContinuousClock.now < deadline else { throw V2HostRoomRecoveryBatchError.deadlineExceeded }
                            let selected = try Self.selectPullInputs(remaining, byteHints: byteHints,
                                maximumResponseBytes: maximumResponseBytes)
                            let batch = try await self.pullSubgroup(selected, database: borrowed,
                                maximumResponseBytes: maximumResponseBytes)
                            byteHints.merge(batch.byteHints) { _, fresh in fresh }
                            guard !batch.results.isEmpty,
                                  Set(batch.results.keys).isSubset(of: Set(remaining.map(\.id))) else {
                                throw V2HostRoomRecoveryBatchError.corruptResult
                            }
                            // No pages survive the next iteration; callbacks are
                            // invoked only after actual COMMIT returned above.
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
        }.get()
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
        // Initial discovery is one bounded metadata query. Subsequent queries
        // inspect only whole pages selected by the non-authoritative hints.
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
        // Setup LOCAL statements are not page reads, including later groups
        // that reuse a handle whose last phase was readBody.
        (database as? any V2ObservedDatabaseHandle)?.loanObservation?.setSQLPhase(.other)
        let attempt = V2RoomTransactionAttempt()
        return try await v2WithRoomScopedTransaction(database: database, timeouts: timeouts) { transaction in
            try await attempt.body {
                guard let sql = transaction as? any SQLDatabase else { throw V2RoomRecoveryReadError.corruptPersistence }
                let observation = (transaction as? any V2ObservedDatabaseHandle)?.loanObservation
                var tokens: [RoomID: V2RoomActivationToken] = [:]
                for item in items {
                    guard item.query.roomID == item.token.roomID else { throw V2RoomActivationLeaseError.activationChanged }
                    if let old = tokens[item.token.roomID], old != item.token {
                        throw V2RoomActivationLeaseError.activationChanged
                    }
                    tokens[item.token.roomID] = item.token
                }
                observation?.setSQLPhase(.fence)
                let fences = try await v2RoomSnapshotReadActivationFences(tokens: Array(tokens.values),
                    sql: sql, timeouts: timeouts)
                var results: [UUID: Result<V2RoomLogQueryResult, any Error>] = [:]
                var input: [V2GroupEventPullBatchInput] = []
                for (ordinal, item) in items.enumerated() {
                    guard let fence = fences[item.token.roomID] else { throw V2RoomRecoveryReadError.corruptPersistence }
                    switch fence {
                    case .failure(let error): results[item.id] = .failure(error)
                    case .success:
                        do { input.append(try .init(ordinal: ordinal, query: item.query)) }
                        catch let error as V2GroupEventLogError { results[item.id] = .success(.failure(.init(error))) }
                    }
                }
                guard !input.isEmpty else { return PullSubgroup(results: results) }
                observation?.setSQLPhase(.readBody)
                let metadata = try await v2GroupEventPullMetadata(input, sql: sql)
                var selected: [V2GroupEventPullBatchInput] = []
                var healthy: [V2GroupEventPullBatchInput] = []
                var byteHints: [UUID: Int] = [:]
                for value in input {
                    guard let facts = metadata[value.ordinal] else { throw V2RoomRecoveryReadError.corruptPersistence }
                    do {
                        try facts.validate()
                        byteHints[items[value.ordinal].id] = try v2PullReplyUpperBound(
                            id: items[value.ordinal].id, query: items[value.ordinal].query, metadata: facts)
                        healthy.append(value)
                    }
                    catch let error as V2GroupEventLogError {
                        results[items[value.ordinal].id] = .success(.failure(.init(error)))
                    }
                }
                var bytes = 2 // encoded aggregate array delimiters, not a guessed record allowance
                for (id, result) in results {
                    let reply: V2PullBudgetReply
                    switch result {
                    case .success(let value): reply = .init(id: id, outcome: .response(.roomLog(value)))
                    case .failure(let error): reply = .init(id: id, outcome: .failure(v2PullWireFailure(error)))
                    }
                    bytes += try JSONEncoder().encode(reply).count + 1
                }
                for value in healthy {
                    let item = items[value.ordinal]
                    let upper = byteHints[item.id]!
                    let additional = upper.addingReportingOverflow(1)
                    guard !additional.overflow else { throw V2RoomRecoveryReadError.corruptPersistence }
                    let bound = bytes.addingReportingOverflow(additional.partialValue)
                    guard !bound.overflow else { throw V2RoomRecoveryReadError.corruptPersistence }
                    if bound.partialValue > maximumResponseBytes {
                        // Conservative estimate is only a packing decision.
                        // A legal native page above256KiB retains its original
                        // scalar behavior and final native encoder cap.
                        if selected.isEmpty, results.isEmpty {
                            let page = try await PostgresV2GroupEventLogStore(database: transaction).pull(
                                roomID: item.query.roomID, actorUserID: item.query.actorUserID,
                                afterRoomSequence: item.query.afterRoomSequence, pageSize: item.query.pageSize)
                            results[item.id] = .success(.page(try .init(page)))
                            return PullSubgroup(results: results, byteHints: byteHints)
                        }
                        continue
                    }
                    selected.append(value); bytes = bound.partialValue
                }
                if !selected.isEmpty {
                    let hydrated = try await v2HydrateGroupEventPulls(selected, sql: sql)
                    for value in selected {
                        let item = items[value.ordinal], facts = metadata[value.ordinal]!
                        do {
                            let page = try v2DecodeGroupEventPull(hydrated[value.ordinal] ?? [],
                                roomID: item.query.roomID, afterRoomSequence: item.query.afterRoomSequence)
                            guard page.events.count == Int(facts.eventCount),
                                  page.nextRoomSequence == max(item.query.afterRoomSequence, UInt64(facts.scannedThrough!)),
                                  page.hasMore == facts.hasMore!,
                                  page.logTrimmedThroughRoomSequence == UInt64(facts.trimmedThrough!) else {
                                throw V2GroupEventLogError.corruptPersistenceState
                            }
                            results[item.id] = .success(.page(try .init(page)))
                        } catch let error as V2GroupEventLogError { results[item.id] = .success(.failure(.init(error))) }
                    }
                }
                // The estimate includes worst-case base64 escaping. Verify the
                // real Codable result before retaining/returning this subgroup.
                let replies = results.map { id, result -> V2PullBudgetReply in
                    switch result {
                    case .success(let value): return .init(id: id, outcome: .response(.roomLog(value)))
                    case .failure(let error): return .init(id: id, outcome: .failure(v2PullWireFailure(error)))
                    }
                }
                guard try JSONEncoder().encode(replies).count <= maximumResponseBytes else {
                    throw V2HostRoomRecoveryBatchError.oversized
                }
                return PullSubgroup(results: results, byteHints: byteHints)
            }
        }
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
