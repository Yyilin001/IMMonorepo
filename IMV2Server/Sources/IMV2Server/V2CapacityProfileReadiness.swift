import Fluent
import IMV2Core
import SQLKit

/// 容量档位就绪检查错误。
public enum V2CapacityProfileReadinessError: Error, Equatable, Sendable {
    /// schema 名不满足标识符格式。
    case invalidSchema(String)
    /// 当前数据库适配器不支持 SQL 查询。
    case unsupportedDatabase
    /// 已持久化的分片准入池上限与本次选择的档位不一致，参数为档位标识。
    case persistedLimitsMismatch(profileID: String)
}

/// 容量档位就绪探针。
///
/// 用于证明已签发的分片准入池仍然实现本进程选定的不可变容量档位。
///
/// 环境变量只是期望的部署配置；准入池一经签发，权威的命令与扇出上限就存放在 PostgreSQL 中。
/// 若以相同档位标识但不同上限对外服务，该部署错误会被推迟到旧持久化窗口写满并开始返回
/// `RATE_LIMITED` 时才暴露，因此必须在启动阶段拦截。
public enum V2CapacityProfileReadiness {
    /// 校验已签发的准入池上限与档位一致。
    ///
    /// - Parameters:
    ///   - database: 待检查的数据库连接。
    ///   - schema: 准入池所在 schema，需符合 `^[A-Za-z_][A-Za-z0-9_]*$`。
    ///   - profile: 本进程选定的容量档位。
    /// - Throws: 连接不支持 SQL 时抛出
    ///   ``V2CapacityProfileReadinessError/unsupportedDatabase``；schema 名非法时抛出
    ///   ``V2CapacityProfileReadinessError/invalidSchema(_:)``；命令窗口、扇出窗口、
    ///   未完成扇出量与未完成计划数任一与档位不符，或查询结果缺失时抛出
    ///   ``V2CapacityProfileReadinessError/persistedLimitsMismatch(profileID:)``。
    public static func verify(
        database: any Database,
        schema: String = "im_v2",
        profile: V2CapacityProfile
    ) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw V2CapacityProfileReadinessError.unsupportedDatabase
        }
        guard schema.range(
            of: "^[A-Za-z_][A-Za-z0-9_]*$",
            options: .regularExpression
        ) != nil else {
            throw V2CapacityProfileReadinessError.invalidSchema(schema)
        }

        let limits = profile.limits
        let row = try await sql.raw("""
            SELECT EXISTS (
                SELECT 1
                FROM \(unsafeRaw: schema).shard_admission_pools
                WHERE capacity_profile_id = \(bind: profile.id)
                  AND (
                      command_window_limit <> \(bind: limits.maxCommandsPerWindow)
                      OR fanout_window_limit <> \(bind: limits.maxFanoutUnitsPerWindow)
                      OR max_outstanding_fanout_units <>
                          \(bind: limits.maxOutstandingFanoutUnits)
                      OR max_outstanding_plans <> \(bind: limits.maxOutstandingPlans)
                  )
            ) AS exists
            """).first(decoding: CapacityProfileMismatchRow.self)
        guard row?.exists == false else {
            throw V2CapacityProfileReadinessError.persistedLimitsMismatch(
                profileID: profile.id
            )
        }
    }
}

private struct CapacityProfileMismatchRow: Decodable {
    let exists: Bool
}
