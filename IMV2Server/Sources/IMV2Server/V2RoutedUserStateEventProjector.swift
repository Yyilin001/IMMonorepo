import Fluent
import Foundation
import IMV2Core
import SQLKit

/// 在用户路由共享围栏内提交当前归属，并向转发中的目标镜像同一序号。
/// 源端先独立提交；镜像完成前始终持有路由围栏，禁止切换到缺少该事件的目标。
public struct V2RoutedUserStateEventProjector: V2UserStateEventProjecting {
    private let routeFence: any V2UserShardRouteFencing
    private let registry: any V2UserShardStorageResolving
    private let controlSchema: String

    /// routeFence 必须使用独立于 registry 数据写入的连接池。
    public init(routeFence: any V2UserShardRouteFencing, registry: any V2UserShardStorageResolving,
                controlSchema: String = "im_v2") throws {
        guard controlSchema.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil else {
            throw V2UserStateEventError.invalidEvent
        }
        self.controlSchema = controlSchema
        self.routeFence = routeFence
        self.registry = registry
    }

    public func project(_ event: V2UserStateEvent) async throws -> UInt64 {
        try await routeFence.withCurrentRoute(for: event.userID) { route, control in
            guard let sql = control as? any SQLDatabase, let user = event.userID.uuidValue else {
                throw V2UserStateEventError.corruptPersistenceState
            }
            let migration = try await sql.raw("""
                SELECT phase, source_bucket, target_bucket
                FROM \(unsafeRaw: controlSchema).user_shard_migrations WHERE user_id = \(bind: user)
                """).first(decoding: UserStateEventMigrationRow.self)
            let owner = try registry.location(for: route.bucket)
            let resolvedPayload = event.kind == .directReadReceipt
                ? try await v2ResolveDirectReadReceiptCandidate(event, sql: sql, schema: controlSchema)
                : nil
            let projection = try await PostgresV2UserStateEventProjector(database: owner.database, schema: owner.schema)
                .projectResolved(event, projectionPayload: resolvedPayload)
            if let migration, migration.sourceBucket == route.bucket,
               migration.phase == .forwarding || migration.phase == .verified {
                let shadow = try registry.location(for: migration.targetBucket)
                _ = try await PostgresV2UserStateEventProjector(database: shadow.database, schema: shadow.schema)
                    .mirrorResolved(event, projection: projection)
            }
            return projection.sequence
        }
    }
}

private struct UserStateEventMigrationRow: Decodable {
    let phase: V2UserShardMigrationPhase
    let sourceBucket: String
    let targetBucket: String
    enum CodingKeys: String, CodingKey {
        case phase, sourceBucket = "source_bucket", targetBucket = "target_bucket"
    }
}
