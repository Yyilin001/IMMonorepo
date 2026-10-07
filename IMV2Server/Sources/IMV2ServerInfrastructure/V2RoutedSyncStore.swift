import IMV2ServerApplication
import IMV2ServerContracts
import Foundation
import IMV2Core

/// 为每次同步操作解析当前逻辑用户归属的同步存储。
///
/// 部署前固定分片配置，所有同步操作使用同一个当前归属。
public struct V2RoutedSyncStore: V2SyncStore, Sendable {
    private let registry: any V2UserShardStorageResolving
    private let routeFence: any V2UserShardRouteFencing
    private let coLocatedControlBuckets: Set<String>
    private let makeStore: @Sendable (V2UserShardStorageLocation) -> any V2SyncStore

    /// 组合归属注册表、路由栅栏与存储构造方式。
    ///
    /// - Parameters:
    ///   - registry: 逻辑归属桶到存储位置的解析器。
    ///   - routeFence: 在事务内锁定当前路由的栅栏。
    ///   - coLocatedControlBuckets: 与控制库同库部署、必须复用栅栏事务连接的归属桶。
    ///   - capabilityProfile: 能力档位标识。
    ///   - maximumEncodedRecordsBytes: 单次返回编码记录的最大字节数，需大于零。
    ///   - makeStore: 自定义存储构造方式；为 `nil` 时使用 PostgreSQL 同步存储。
    ///
    /// 最大字节数非正时直接失败；默认存储构造方式会把档位与字节上限透传给同步存储。
    public init(
        registry: any V2UserShardStorageResolving,
        routeFence: any V2UserShardRouteFencing,
        coLocatedControlBuckets: Set<String> = [],
        capabilityProfile: String = "base",
        maximumEncodedRecordsBytes: Int = 48 * 1_024,
        makeStore: (@Sendable (V2UserShardStorageLocation) -> any V2SyncStore)? = nil
    ) {
        precondition(maximumEncodedRecordsBytes > 0)
        self.registry = registry
        self.routeFence = routeFence
        self.coLocatedControlBuckets = coLocatedControlBuckets
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

    /// 在已锁定路由的事务内解析存储位置并执行操作。
    ///
    /// 与控制库同库部署的归属必须复用栅栏事务的数据库句柄：
    /// 在第一个连接仍持有路由锁时另开池化连接，会在单连接部署中自锁，
    /// 也无法与栅栏共享同一事务边界。
    ///
    /// - Parameters:
    ///   - userID: 目标用户。
    ///   - operation: 在解析出的存储上执行的操作。
    /// - Returns: 操作结果。
    /// - Throws: 路由解析或操作本身抛出的错误。
    private func withStore<Result: Sendable>(
        for userID: UserID,
        _ operation: @escaping @Sendable (any V2SyncStore) async throws -> Result
    ) async throws -> Result {
        // Capture the trusted purpose before the route fence's first physical
        // borrow. Detached EventLoop callbacks must not infer it later. The
        // scope also covers an independent owner borrow in split deployments.
        try await V2PhysicalDatabaseLoanScope.$purpose.withValue(.sync) {
          try await V2DatabaseLoanObservationContext.$source.withValue(.sync) {
          try await routeFence.withCurrentRoute(for: userID) { route, fencedDatabase in
            var location = try registry.location(for: route.bucket)
            // 同位置的分片必须使用栅栏事务的数据库句柄。当第一条连接持有
            // 路由锁时再打开第二条池连接，在单连接部署中可能发生自死锁，
            // 而且第二条连接也不共享事务边界。
            if coLocatedControlBuckets.contains(route.bucket) {
                location = try .init(
                    bucket: location.bucket, database: fencedDatabase,
                    schema: location.schema
                )
            }
            return try await V2DatabaseLoanObservationContext.$source.withValue(.sync) {
                try await operation(makeStore(location))
            }
          }
          }
        }
    }
}
