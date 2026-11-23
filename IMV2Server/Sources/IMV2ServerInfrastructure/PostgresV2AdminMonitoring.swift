import FluentKit
import IMV2ServerContracts
import Foundation
import SQLKit

public struct PostgresV2AdminMonitoring: Sendable {
    private let database: any Database
    public init(database: any Database) { self.database = database }
    /// 一条聚合查询同时验证数据库与审计表可读。结果失败时不得转换为零。
    public func observe() async throws -> V2AdminDatabaseObservation {
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw V2AdminError.unavailable }
            try await sql.raw("SET LOCAL statement_timeout = '2000ms'").run()
            struct Row: Decodable { let pending: Int64; let oldest: Date? }
            guard let row = try await sql.raw("""
                SELECT count(*) AS pending, min(occurred_at) AS oldest FROM im_admin.audit
                WHERE action = 'account_disable' AND outcome = 'pending'
                """).first(decoding: Row.self) else { throw V2AdminError.unavailable }
            return .init(pendingDisables: row.pending, oldestPendingAt: row.oldest)
        }
    }
}
