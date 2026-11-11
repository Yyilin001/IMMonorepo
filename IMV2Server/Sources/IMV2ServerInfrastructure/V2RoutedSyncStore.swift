import IMV2ServerApplication
import IMV2ServerContracts
import Foundation
import IMV2Core

/// 从部署期固定路由解析用户归属，仅向归属库借用同步事务。
///
/// 部署前固定分片配置，所有同步操作使用同一个当前归属。
public struct V2RoutedSyncStore: V2SyncStore, Sendable {
    private let registry: any V2UserShardStorageResolving
    private let router: any V2UserShardRouter
    private let makeStore: @Sendable (V2UserShardStorageLocation) -> any V2SyncStore

    /// 组合归属注册表、部署路由与存储构造方式。
    ///
    /// - Parameters:
    ///   - registry: 逻辑归属桶到存储位置的解析器。
    ///   - router: 与实时通知共享的部署路由快照，变更需要重新部署。
    ///   - capabilityProfile: 能力档位标识。
    ///   - maximumEncodedRecordsBytes: 单次返回编码记录的最大字节数，需大于零。
    ///   - makeStore: 自定义存储构造方式；为 `nil` 时使用 PostgreSQL 同步存储。
    ///
    /// 最大字节数非正时直接失败；默认存储构造方式会把档位与字节上限透传给同步存储。
    public init(
        registry: any V2UserShardStorageResolving,
        router: any V2UserShardRouter,
        capabilityProfile: String = "base",
        maximumEncodedRecordsBytes: Int = 48 * 1_024,
        makeStore: (@Sendable (V2UserShardStorageLocation) -> any V2SyncStore)? = nil
    ) {
        precondition(maximumEncodedRecordsBytes > 0)
        self.registry = registry
        self.router = router
        self.makeStore = makeStore ?? {
            PostgresV2SyncStore(
                database: $0.database, schema: $0.schema,
                capabilityProfile: capabilityProfile,
                maximumEncodedRecordsBytes: maximumEncodedRecordsBytes
            )
        }
    }

    /// 拉取用户的同步记录。
    ///
    /// - Parameters:
    ///   - userID: 目标用户。
    ///   - deviceID: 发起同步的设备。
    ///   - syncToken: 上次同步令牌；为空表示从头开始。
    ///   - maxRecords: 本次最多返回的记录数。
    ///   - requireSnapshot: 是否要求以快照方式同步。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 本次同步拉取结果。
    /// - Throws: 路由解析、归属校验或存储失败时抛出。
    public func pull(userID: UserID, deviceID: DeviceID, syncToken: V2SyncToken?, maxRecords: Int, requireSnapshot: Bool = false, now: Date) async throws -> V2SyncPullResult {
        try await withStore(for: userID) {
            try await $0.pull(userID: userID, deviceID: deviceID, syncToken: syncToken, maxRecords: maxRecords, requireSnapshot: requireSnapshot, now: now)
        }
    }

    /// 确认已连续处理的同步序号。
    ///
    /// - Parameters:
    ///   - userID: 目标用户。
    ///   - deviceID: 发起同步的设备。
    ///   - generation: 同步代次。
    ///   - highestContiguousSequence: 已连续处理的最高序号。
    ///   - receipt: 本次确认回执。
    ///   - now: 服务端统一授时时刻。
    /// - Throws: 路由解析、归属校验或存储失败时抛出。
    public func acknowledge(userID: UserID, deviceID: DeviceID, generation: UInt64, highestContiguousSequence: UInt64, receipt: V2SyncReceipt, now: Date) async throws {
        try await withStore(for: userID) {
            try await $0.acknowledge(userID: userID, deviceID: deviceID, generation: generation, highestContiguousSequence: highestContiguousSequence, receipt: receipt, now: now)
        }
    }

    /// 读取快照清单。
    ///
    /// - Parameters:
    ///   - userID: 目标用户。
    ///   - deviceID: 发起同步的设备。
    ///   - snapshotID: 目标快照标识。
    ///   - generation: 同步代次。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 快照清单。
    /// - Throws: 路由解析、归属校验或存储失败时抛出。
    public func fetchSnapshotManifest(userID: UserID, deviceID: DeviceID, snapshotID: SnapshotID, generation: UInt64, now: Date) async throws -> V2SnapshotManifest {
        try await withStore(for: userID) {
            try await $0.fetchSnapshotManifest(userID: userID, deviceID: deviceID, snapshotID: snapshotID, generation: generation, now: now)
        }
    }

    /// 读取快照分页。
    ///
    /// - Parameters:
    ///   - userID: 目标用户。
    ///   - deviceID: 发起同步的设备。
    ///   - snapshotID: 目标快照标识。
    ///   - generation: 同步代次。
    ///   - rootDigest: 根摘要，用于确认请求的是同一份快照。
    ///   - index: 分页序号。
    ///   - now: 服务端统一授时时刻。
    /// - Returns: 快照分页。
    /// - Throws: 路由解析、归属校验或存储失败时抛出。
    public func fetchSnapshotPage(userID: UserID, deviceID: DeviceID, snapshotID: SnapshotID, generation: UInt64, rootDigest: String, index: UInt32, now: Date) async throws -> V2SnapshotPage {
        try await withStore(for: userID) {
            try await $0.fetchSnapshotPage(userID: userID, deviceID: deviceID, snapshotID: snapshotID, generation: generation, rootDigest: rootDigest, index: index, now: now)
        }
    }

    /// 确认快照已接收完成。
    ///
    /// - Parameters:
    ///   - userID: 目标用户。
    ///   - deviceID: 发起同步的设备。
    ///   - snapshotID: 目标快照标识。
    ///   - generation: 同步代次。
    ///   - baseSequence: 快照的基准序号。
    ///   - receipt: 本次确认回执。
    ///   - now: 服务端统一授时时刻。
    /// - Throws: 路由解析、归属校验或存储失败时抛出。
    public func acknowledgeSnapshot(userID: UserID, deviceID: DeviceID, snapshotID: SnapshotID, generation: UInt64, baseSequence: UInt64, receipt: V2SyncReceipt, now: Date) async throws {
        try await withStore(for: userID) {
            try await $0.acknowledgeSnapshot(userID: userID, deviceID: deviceID, snapshotID: snapshotID, generation: generation, baseSequence: baseSequence, receipt: receipt, now: now)
        }
    }

    /// 路由不借用控制库；游标、设备吊销和保留下界仍在归属库事务内校验。
    private func withStore<Result: Sendable>(
        for userID: UserID,
        _ operation: @escaping @Sendable (any V2SyncStore) async throws -> Result
    ) async throws -> Result {
        try await V2PhysicalDatabaseLoanScope.$purpose.withValue(.sync) {
            try await V2DatabaseLoanObservationContext.$source.withValue(.sync) {
                let routes = try await router.routes(for: [userID])
                guard routes.count == 1 else { throw V2UserShardRouterError.resultCountMismatch }
                let location = try registry.location(for: routes[0].bucket)
                return try await operation(makeStore(location))
            }
        }
    }
}
