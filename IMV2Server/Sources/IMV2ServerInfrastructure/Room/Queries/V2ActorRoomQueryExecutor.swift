import IMV2ServerApplication
import IMV2ServerContracts
import FluentKit
import IMV2ActorContracts
import IMV2Core
import SQLKit

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
        try await withFencedRead(roomIDs: [query.roomID], tokens: [token]) { transaction in
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
        try await withFencedRead(roomIDs: query.roomIDs, tokens: tokens) { transaction in
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

    func withFencedRead<Value: Sendable>(
        roomIDs: [RoomID], tokens: [V2RoomActivationToken],
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
            return try await v2WithRoomScopedTransaction(database: database, timeouts: timeouts) { transaction in
                try await attempt.body {
                    guard let sql = transaction as? any SQLDatabase else {
                        throw V2RoomRecoveryReadError.corruptPersistence
                    }
                    try await v2RequireRoomActivations(tokens: tokens, sql: sql, timeouts: timeouts)
                    return try await operation(transaction)
                }
            }
        } catch {
            throw error
        }
    }
}
