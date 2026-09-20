import Fluent
import Foundation
import IMV2Core
import SQLKit

/// 用户同步中不参与扇出的一小部分（关系、拉黑与接收偏好）以控制面存储为权威。
///
/// 该边界把已提交记录镜像到当前写入归属；当迁移仍在源端写入时，也会镜像到迁移目标。
/// 来源操作标识就是持久化重试键，因此响应丢失后可以安全地重复镜像，
/// 而不会额外占用目标端序号。
public struct V2UserShardProjectionShadowRequest: Sendable {
    /// 目标用户。
    public let userID: UserID
    /// 来源事件标识。
    public let sourceEventID: EventID
    /// 需要镜像的投影类型集合。
    public let projectionKinds: Set<String>

    /// 保存镜像请求。
    ///
    /// - Parameters:
    ///   - userID: 目标用户。
    ///   - sourceEventID: 来源事件标识。
    ///   - projectionKinds: 投影类型集合。
    public init(
        userID: UserID,
        sourceEventID: EventID,
        projectionKinds: Set<String>
    ) {
        self.userID = userID
        self.sourceEventID = sourceEventID
        self.projectionKinds = projectionKinds
    }
}

/// 用户分片投影影子转发能力。
public protocol V2UserShardProjectionShadowing: Sendable {
    /// 把既有控制面记录写入用户当前写入归属，并在需要时镜像到迁移目标。
    ///
    /// 返回的序号属于当前写入归属，可用于尽力而为的实时同步提示；
    /// 返回 `nil` 表示控制面存储中不存在所请求的来源投影。
    ///
    /// - Parameters:
    ///   - userID: 目标用户。
    ///   - sourceEventID: 来源事件标识。
    ///   - projectionKinds: 投影类型集合。
    /// - Returns: 当前写入归属的序号；无来源投影时为 `nil`。
    /// - Throws: 路由或存储失败时抛出。
    func shadowIfForwarding(userID: UserID, sourceEventID: EventID, projectionKinds: Set<String>) async throws -> UInt64?

    /// 镜像一个有界的已提交微批。
    ///
    /// 结果保持请求顺序，语义等同于逐条调用标量方法。具体存储可以把路由栅栏与来源读取
    /// 合并为集合式操作；默认实现保证既有适配器行为正确。
    ///
    /// - Parameter requests: 待镜像请求列表。
    /// - Returns: 与输入顺序对应的序号结果。
    /// - Throws: 路由或存储失败时抛出。
    func shadowIfForwarding(
        _ requests: [V2UserShardProjectionShadowRequest]
    ) async throws -> [UInt64?]
}

public extension V2UserShardProjectionShadowing {
    /// 逐条镜像的兼容实现。
    ///
    /// - Parameter requests: 待镜像请求列表。
    /// - Returns: 与输入顺序对应的序号结果。
    /// - Throws: 任一条目失败时抛出。
    func shadowIfForwarding(
        _ requests: [V2UserShardProjectionShadowRequest]
    ) async throws -> [UInt64?] {
        var results: [UInt64?] = []
        results.reserveCapacity(requests.count)
        for request in requests {
            results.append(try await shadowIfForwarding(
                userID: request.userID,
                sourceEventID: request.sourceEventID,
                projectionKinds: request.projectionKinds
            ))
        }
        return results
    }
}

/// 基于 PostgreSQL 的用户分片投影影子转发实现。
public struct V2PostgresUserShardProjectionShadowForwarder: V2UserShardProjectionShadowing, Sendable {
    private let registry: any V2UserShardStorageResolving
    private let routeFence: any V2UserShardRouteFencing
    private let batchRouteFence: (any V2UserShardRouteBatchFencing)?
    private let coLocatedControlBuckets: Set<String>

    /// 组合归属解析器与路由栅栏。
    ///
    /// - Parameters:
    ///   - registry: 用户归属存储解析器。
    ///   - routeFence: 用户归属栅栏。
    ///   - batchRouteFence: 可选的批量路由栅栏。
    ///   - coLocatedControlBuckets: 与控制库同库部署、需复用栅栏连接的归属桶。
    public init(
        registry: any V2UserShardStorageResolving,
        routeFence: any V2UserShardRouteFencing,
        batchRouteFence: (any V2UserShardRouteBatchFencing)? = nil,
        coLocatedControlBuckets: Set<String> = []
    ) {
        self.registry = registry
        self.routeFence = routeFence
        self.batchRouteFence = batchRouteFence
        self.coLocatedControlBuckets = coLocatedControlBuckets
    }

    /// 镜像单条已提交投影。
    ///
    /// - Parameters:
    ///   - userID: 目标用户。
    ///   - sourceEventID: 来源事件标识。
    ///   - projectionKinds: 投影类型集合。
    /// - Returns: 当前写入归属的序号；无来源投影时为 `nil`。
    /// - Throws: 路由或存储失败时抛出。
    public func shadowIfForwarding(userID: UserID, sourceEventID: EventID, projectionKinds: Set<String>) async throws -> UInt64? {
        try await routeFence.withCurrentRoute(for: userID) { route, fencedDatabase in
            guard let sql = fencedDatabase as? any SQLDatabase,
                  let userUUID = UUID(uuidString: userID.rawValue)
            else { throw V2RoomWriteStoreError.corruptPersistenceState }
            let migration = try await sql.raw("""
                SELECT phase, source_bucket, target_bucket
                FROM im_v2.user_shard_migrations
                WHERE user_id = \(bind: userUUID)
                """).first(decoding: ShadowMigrationRow.self)?.record
            return try await shadow(
                userID: userID, sourceEventID: sourceEventID,
                projectionKinds: projectionKinds, route: route,
                controlDatabase: fencedDatabase, migration: migration
            )
        }
    }

    /// 批量镜像已提交投影。
    ///
    /// 请求为空时直接返回空结果；数量超过 1024 或未配置批量栅栏时，
    /// 退化为逐条镜像以保持语义一致。
    ///
    /// - Parameter requests: 待镜像请求列表。
    /// - Returns: 与输入顺序对应的序号结果。
    /// - Throws: 路由或存储失败时抛出。
    public func shadowIfForwarding(
        _ requests: [V2UserShardProjectionShadowRequest]
    ) async throws -> [UInt64?] {
        guard !requests.isEmpty else { return [] }
        guard requests.count <= 1_024, let batchRouteFence else {
            var results: [UInt64?] = []
            results.reserveCapacity(requests.count)
            for request in requests {
                results.append(try await shadowIfForwarding(
                    userID: request.userID,
                    sourceEventID: request.sourceEventID,
                    projectionKinds: request.projectionKinds
                ))
            }
            return results
        }
        return try await batchRouteFence.withCurrentRoutes(
            for: requests.map(\.userID)
        ) { routes, fencedDatabase in
            guard routes.count == requests.count else {
                throw V2UserShardRouterError.resultCountMismatch
            }
            return try await shadowBatch(
                requests: requests,
                routes: routes,
                controlDatabase: fencedDatabase
            )
        }
    }

    private func shadow(
        userID: UserID, sourceEventID: EventID,
        projectionKinds: Set<String>, route: V2UserShardRoute,
        controlDatabase: any Database, migration: ShadowMigration?
    ) async throws -> UInt64? {
        guard !projectionKinds.isEmpty,
              let sql = controlDatabase as? any SQLDatabase,
              let userUUID = UUID(uuidString: userID.rawValue),
              let eventUUID = UUID(uuidString: sourceEventID.rawValue)
        else { return nil }
        var current = try registry.location(for: route.bucket)
        if coLocatedControlBuckets.contains(route.bucket) {
            current = try .init(
                bucket: current.bucket, database: controlDatabase,
                schema: current.schema
            )
        }
        var liveSequence: UInt64?
        for kind in projectionKinds.sorted() {
            guard let row = try await sql.raw("""
                SELECT user_sync_sequence, projection_kind, payload::text AS payload_json, created_at
                FROM im_v2.user_projection_effects
                WHERE user_id = \(bind: userUUID) AND source_event_id = \(bind: eventUUID)
                  AND projection_kind = \(bind: kind)
                """).first(decoding: ShadowSourceRow.self)
            else { continue }
            let currentProjector = try PostgresV2UserProjectionStore(database: current.database, schema: current.schema)
            let sequence = try await currentProjector.projectAllocated(
                userID: userID, sourceEventID: sourceEventID, projectionKind: row.projectionKind,
                payloadJSON: row.payloadJSON, createdAt: row.createdAt.date, persistedCreatedAt: row.createdAt
            )
            // A single source event can carry a profile projection plus an
            // invalidation. The wake hint must cover the last
            // mirrored sequence, otherwise a client could stop just before
            // the invalidation and retain stale profile data.
            liveSequence = max(liveSequence ?? 0, sequence)
            if let migration,
               (migration.phase == .forwarding || migration.phase == .verified),
               migration.sourceBucket == route.bucket {
                var target = try registry.location(for: migration.targetBucket)
                if coLocatedControlBuckets.contains(migration.targetBucket) {
                    target = try .init(
                        bucket: target.bucket, database: controlDatabase,
                        schema: target.schema
                    )
                }
                let targetProjector = try PostgresV2UserProjectionStore(database: target.database, schema: target.schema)
                _ = try await targetProjector.mirror(.init(
                    userID: userID, sequence: sequence, sourceEventID: sourceEventID,
                    projectionKind: row.projectionKind, payloadJSON: row.payloadJSON, createdAt: row.createdAt.date
                ), persistedCreatedAt: row.createdAt)
            }
        }
        return liveSequence
    }

    /// 有界批量镜像实现，语义与逐条标量路径一致。
    ///
    /// 常见的同置拓扑下：一次性获取所有切换栅栏，用两条集合查询加载全部迁移/来源行，
    /// 并复用来源 Sync 序号作为已物化的实时结果。
    /// 远端路由以及处于活跃转发的迁移，则保留与标量路径相同的目标事务与幂等校验。
    ///
    /// - Parameters:
    ///   - requests: 待镜像的请求列表，返回结果顺序与之一致。
    ///   - routes: 各目标用户对应的用户分片路由。
    ///   - controlDatabase: 控制面数据库连接。
    /// - Returns: 与输入顺序对应的序号结果。
    /// - Throws: 路由或存储失败时抛出。
    private func shadowBatch(
        requests: [V2UserShardProjectionShadowRequest],
        routes: [V2UserShardRoute],
        controlDatabase: any Database
    ) async throws -> [UInt64?] {
        guard let sql = controlDatabase as? any SQLDatabase else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }
        let flattened = try requests.enumerated().flatMap { ordinal, request in
            guard let userID = UUID(uuidString: request.userID.rawValue),
                  let sourceEventID = UUID(uuidString: request.sourceEventID.rawValue)
            else { throw V2RoomWriteStoreError.corruptPersistenceState }
            return request.projectionKinds.sorted().map {
                ShadowBatchInput(
                    ordinal: ordinal,
                    userID: userID,
                    sourceEventID: sourceEventID,
                    projectionKind: $0
                )
            }
        }
        guard flattened.count <= 2_048 else {
            throw V2RoomWriteStoreError.corruptPersistenceState
        }

        let uniqueUserIDs = Array(Set(requests.map(\.userID.rawValue))).sorted()
        let userIDsJSON = try shadowJSON(uniqueUserIDs)
        let migrationRows = try await sql.raw("""
            WITH requested AS (
                SELECT value::uuid AS user_id
                FROM jsonb_array_elements_text(\(bind: userIDsJSON)::jsonb)
                     AS values(value)
            )
            SELECT migration.user_id, migration.phase,
                   migration.source_bucket, migration.target_bucket
            FROM im_v2.user_shard_migrations AS migration
            JOIN requested USING (user_id)
            """).all(decoding: ShadowBatchMigrationRow.self)
        var migrations: [UserID: ShadowMigration] = [:]
        for row in migrationRows {
            let userID = try UserID(row.userID.uuidString)
            guard migrations[userID] == nil else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            migrations[userID] = row.record
        }

        var sourceRowsByOrdinal: [[ShadowSourceRow]] = Array(
            repeating: [], count: requests.count
        )
        if !flattened.isEmpty {
            let inputJSON = try shadowJSON(flattened)
            let sourceRows = try await sql.raw("""
                WITH input AS MATERIALIZED (
                    SELECT input.ordinal, input.user_id,
                           input.source_event_id, input.projection_kind
                    FROM jsonb_to_recordset(\(bind: inputJSON)::jsonb) AS input(
                        ordinal integer,
                        user_id uuid,
                        source_event_id uuid,
                        projection_kind text
                    )
                )
                SELECT input.ordinal, effect.user_sync_sequence,
                       effect.projection_kind,
                       effect.payload::text AS payload_json,
                       effect.created_at
                FROM input
                JOIN im_v2.user_projection_effects AS effect
                  ON effect.user_id = input.user_id
                 AND effect.source_event_id = input.source_event_id
                 AND effect.projection_kind = input.projection_kind
                ORDER BY input.ordinal, input.projection_kind
                """).all(decoding: ShadowBatchSourceRow.self)
            for row in sourceRows {
                guard sourceRowsByOrdinal.indices.contains(row.ordinal) else {
                    throw V2RoomWriteStoreError.corruptPersistenceState
                }
                sourceRowsByOrdinal[row.ordinal].append(row.record)
            }
        }

        var results = Array<UInt64?>(repeating: nil, count: requests.count)
        for index in requests.indices {
            let request = requests[index]
            let route = routes[index]
            let migration = migrations[request.userID]
            let sourceRows = sourceRowsByOrdinal[index]
            guard sourceRows.count <= request.projectionKinds.count else {
                throw V2RoomWriteStoreError.corruptPersistenceState
            }
            var current = try registry.location(for: route.bucket)
            let currentIsCoLocated = coLocatedControlBuckets.contains(route.bucket)
            if currentIsCoLocated {
                current = try .init(
                    bucket: current.bucket,
                    database: controlDatabase,
                    schema: current.schema
                )
            }

            var liveSequence: UInt64?
            for row in sourceRows {
                let sequence: UInt64
                if currentIsCoLocated {
                    sequence = try shadowUnsigned(row.sequence)
                } else {
                    let projector = try PostgresV2UserProjectionStore(
                        database: current.database,
                        schema: current.schema
                    )
                    sequence = try await projector.projectAllocated(
                        userID: request.userID,
                        sourceEventID: request.sourceEventID,
                        projectionKind: row.projectionKind,
                        payloadJSON: row.payloadJSON,
                        createdAt: row.createdAt.date,
                        persistedCreatedAt: row.createdAt
                    )
                }
                liveSequence = max(liveSequence ?? 0, sequence)
                if let migration,
                   (migration.phase == .forwarding || migration.phase == .verified),
                   migration.sourceBucket == route.bucket {
                    var target = try registry.location(for: migration.targetBucket)
                    if coLocatedControlBuckets.contains(migration.targetBucket) {
                        target = try .init(
                            bucket: target.bucket,
                            database: controlDatabase,
                            schema: target.schema
                        )
                    }
                    let targetProjector = try PostgresV2UserProjectionStore(
                        database: target.database,
                        schema: target.schema
                    )
                    _ = try await targetProjector.mirror(.init(
                        userID: request.userID,
                        sequence: sequence,
                        sourceEventID: request.sourceEventID,
                        projectionKind: row.projectionKind,
                        payloadJSON: row.payloadJSON,
                        createdAt: row.createdAt.date
                    ), persistedCreatedAt: row.createdAt)
                }
            }
            results[index] = liveSequence
        }
        return results
    }
}

private struct ShadowSourceRow: Decodable {
    let sequence: Int64
    let projectionKind: String
    let payloadJSON: String
    // Preserve the source's database value through both allocation and mirror.
    let createdAt: V2PostgresTimestamp
    enum CodingKeys: String, CodingKey {
        case sequence = "user_sync_sequence"
        case projectionKind = "projection_kind"
        case payloadJSON = "payload_json"
        case createdAt = "created_at"
    }
}
private struct ShadowMigration: Sendable {
    let phase: V2UserShardMigrationPhase
    let sourceBucket: String
    let targetBucket: String
}
private struct ShadowMigrationRow: Decodable {
    let phase: V2UserShardMigrationPhase
    let sourceBucket: String
    let targetBucket: String
    var record: ShadowMigration { .init(phase: phase, sourceBucket: sourceBucket, targetBucket: targetBucket) }
    enum CodingKeys: String, CodingKey {
        case phase
        case sourceBucket = "source_bucket"
        case targetBucket = "target_bucket"
    }
}

private struct ShadowBatchInput: Encodable {
    let ordinal: Int
    let userID: UUID
    let sourceEventID: UUID
    let projectionKind: String
    enum CodingKeys: String, CodingKey {
        case ordinal
        case userID = "user_id"
        case sourceEventID = "source_event_id"
        case projectionKind = "projection_kind"
    }
}

private struct ShadowBatchMigrationRow: Decodable {
    let userID: UUID
    let phase: V2UserShardMigrationPhase
    let sourceBucket: String
    let targetBucket: String
    var record: ShadowMigration {
        .init(phase: phase, sourceBucket: sourceBucket, targetBucket: targetBucket)
    }
    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case phase
        case sourceBucket = "source_bucket"
        case targetBucket = "target_bucket"
    }
}

private struct ShadowBatchSourceRow: Decodable {
    let ordinal: Int
    let sequence: Int64
    let projectionKind: String
    let payloadJSON: String
    let createdAt: V2PostgresTimestamp
    var record: ShadowSourceRow {
        .init(
            sequence: sequence,
            projectionKind: projectionKind,
            payloadJSON: payloadJSON,
            createdAt: createdAt
        )
    }
    enum CodingKeys: String, CodingKey {
        case ordinal
        case sequence = "user_sync_sequence"
        case projectionKind = "projection_kind"
        case payloadJSON = "payload_json"
        case createdAt = "created_at"
    }
}

private func shadowJSON<T: Encodable>(_ value: T) throws -> String {
    let data = try JSONEncoder().encode(value)
    guard let json = String(data: data, encoding: .utf8) else {
        throw V2RoomWriteStoreError.corruptPersistenceState
    }
    return json
}

private func shadowUnsigned(_ value: Int64) throws -> UInt64 {
    guard value > 0 else { throw V2RoomWriteStoreError.corruptPersistenceState }
    return UInt64(value)
}
