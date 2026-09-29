import IMV2ServerApplication
import IMV2ServerContracts
import FluentKit
import Foundation
import IMV2Core
import SQLKit

/// 基于 PostgreSQL 的用户分片投影当前归属投递实现。
public struct V2PostgresUserShardProjectionDelivery: V2UserShardProjectionDelivering, Sendable {
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

    /// 投递单条已提交投影。
    ///
    /// - Parameters:
    ///   - userID: 目标用户。
    ///   - sourceEventID: 来源事件标识。
    ///   - projectionKinds: 投影类型集合。
    /// - Returns: 当前写入归属的序号；无来源投影时为 `nil`。
    /// - Throws: 路由或存储失败时抛出。
    public func deliverToCurrentShard(userID: UserID, sourceEventID: EventID, projectionKinds: Set<String>) async throws -> UInt64? {
        try await routeFence.withCurrentRoute(for: userID) { route, fencedDatabase in
            guard fencedDatabase is any SQLDatabase,
                  UUID(uuidString: userID.rawValue) != nil
            else { throw V2RoomWriteStoreError.corruptPersistenceState }
            return try await deliver(
                userID: userID, sourceEventID: sourceEventID,
                projectionKinds: projectionKinds, route: route,
                controlDatabase: fencedDatabase
            )
        }
    }

    /// 批量投递已提交投影。
    ///
    /// 请求为空时直接返回空结果；数量超过 1024 或未配置批量栅栏时，
    /// 退化为逐条投递以保持语义一致。
    ///
    /// - Parameter requests: 待投递请求列表。
    /// - Returns: 与输入顺序对应的序号结果。
    /// - Throws: 路由或存储失败时抛出。
    public func deliverToCurrentShard(
        _ requests: [V2UserShardProjectionDeliveryRequest]
    ) async throws -> [UInt64?] {
        guard !requests.isEmpty else { return [] }
        guard requests.count <= 1_024, let batchRouteFence else {
            var results: [UInt64?] = []
            results.reserveCapacity(requests.count)
            for request in requests {
                results.append(try await deliverToCurrentShard(
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
            return try await deliverBatch(
                requests: requests,
                routes: routes,
                controlDatabase: fencedDatabase
            )
        }
    }

    private func deliver(
        userID: UserID, sourceEventID: EventID,
        projectionKinds: Set<String>, route: V2UserShardRoute,
        controlDatabase: any Database
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
                """).first(decoding: ProjectionSourceRow.self)
            else { continue }
            let currentProjector = try PostgresV2UserProjectionStore(database: current.database, schema: current.schema)
            let sequence = try await currentProjector.projectAllocated(
                userID: userID, sourceEventID: sourceEventID, projectionKind: row.projectionKind,
                payloadJSON: row.payloadJSON, createdAt: row.createdAt.date, persistedCreatedAt: row.createdAt
            )
            // 单条源事件可能同时携带资料投影和失效通知。
            // 唤醒提示必须覆盖最后已投递的序号，
            // 否则客户端可能在失效通知前停止拉取，保留过期资料。
            liveSequence = max(liveSequence ?? 0, sequence)

        }
        return liveSequence
    }

    /// 有界批量投递实现，语义与逐条标量路径一致。
    ///
    /// 同库部署下批量读取当前路由与控制来源行，
    /// 并复用来源 Sync 序号作为已物化的实时结果。
    /// 远端路由保留与标量路径相同的目标事务与幂等校验。
    ///
    /// - Parameters:
    ///   - requests: 待投递的请求列表，返回结果顺序与之一致。
    ///   - routes: 各目标用户对应的用户分片路由。
    ///   - controlDatabase: 控制面数据库连接。
    /// - Returns: 与输入顺序对应的序号结果。
    /// - Throws: 路由或存储失败时抛出。
    private func deliverBatch(
        requests: [V2UserShardProjectionDeliveryRequest],
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
                ProjectionBatchInput(
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

        var sourceRowsByOrdinal: [[ProjectionSourceRow]] = Array(
            repeating: [], count: requests.count
        )
        if !flattened.isEmpty {
            let inputJSON = try deliveryJSON(flattened)
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
                """).all(decoding: ProjectionBatchSourceRow.self)
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
                    sequence = try deliveryUnsigned(row.sequence)
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

            }
            results[index] = liveSequence
        }
        return results
    }
}

private struct ProjectionSourceRow: Decodable {
    let sequence: Int64
    let projectionKind: String
    let payloadJSON: String
    // 在分配与投递两个阶段都保留源数据库的原始值。
    let createdAt: V2PersistenceTimestamp
    enum CodingKeys: String, CodingKey {
        case sequence = "user_sync_sequence"
        case projectionKind = "projection_kind"
        case payloadJSON = "payload_json"
        case createdAt = "created_at"
    }
}
private struct ProjectionBatchInput: Encodable {
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

private struct ProjectionBatchSourceRow: Decodable {
    let ordinal: Int
    let sequence: Int64
    let projectionKind: String
    let payloadJSON: String
    let createdAt: V2PersistenceTimestamp
    var record: ProjectionSourceRow {
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

private func deliveryJSON<T: Encodable>(_ value: T) throws -> String {
    let data = try JSONEncoder().encode(value)
    guard let json = String(data: data, encoding: .utf8) else {
        throw V2RoomWriteStoreError.corruptPersistenceState
    }
    return json
}

private func deliveryUnsigned(_ value: Int64) throws -> UInt64 {
    guard value > 0 else { throw V2RoomWriteStoreError.corruptPersistenceState }
    return UInt64(value)
}
