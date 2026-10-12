import Foundation
import Logging
import NIOCore
import PostgresKit
import PostgresNIO
import SQLKit

/// Fixed-field ordinary-message SQL boundary. No Codable/JSON encoding fallback.
/// Its future includes this statement's own idle ReadyForQuery, not a global drain.
struct V2IndependentRoomSQLDatabase: SQLDatabase {
    let base: any SQLDatabase
    let connection: PostgresConnection
    var logger: Logger { base.logger }
    var eventLoop: any EventLoop { connection.eventLoop }
    var dialect: any SQLDialect { base.dialect }
    var version: (any SQLDatabaseReportedVersion)? { base.version }
    var queryLogLevel: Logger.Level? { nil }

    func execute(sql expression: any SQLExpression,
        _ onRow: @escaping @Sendable (any SQLRow) -> Void) -> EventLoopFuture<Void> {
        let query: PostgresQuery
        do {
            let (sql, values) = serialize(expression)
            guard sql.hasPrefix("/* imv2_plain_direct_append */") else {
                throw PostgresIndependentQueryError.notSubmitted
            }
            var bindings = PostgresBindings(capacity: values.count)
            for value in values {
                switch value {
                case let v as UUID: bindings.append(v)
                case let v as Data: try bindings.append(v)
                case let v as String: bindings.append(v)
                case let v as Int: bindings.append(v)
                case let v as Int16: bindings.append(v)
                case let v as Int64: bindings.append(v)
                case let v as Bool: bindings.append(v)
                case let v as UUID?: bindings.append(v)
                case let v as Data?: try bindings.append(v)
                case let v as String?: bindings.append(v)
                case let v as Int64?: bindings.append(v)
                default: throw PostgresIndependentQueryError.notSubmitted
                }
            }
            query = .init(unsafeSQL: sql, binds: bindings)
        } catch { return eventLoop.makeFailedFuture(error) }
        let timeline = V2OwnerConnectionTimeline.current
        let start = ContinuousClock.now
        timeline?.sqlStarted(at: start)
        let result = connection.independentQuery(query)
        result.whenComplete { _ in timeline?.sqlFinished(label: .write, startedAt: start, at: .now) }
        return result.map { for row in $0.rows { onRow(row.sql()) } }
    }
    func execute(sql expression: any SQLExpression,
        _ onRow: @escaping @Sendable (any SQLRow) -> Void) async throws {
        let timeline = V2OwnerConnectionTimeline.current
        let actual: EventLoopFuture<Void> = execute(sql: expression, onRow)
        try await actual.get()
        if let ended = timeline?.marker("write_future_completed") {
            timeline?.record(.ownerWriteResume, from: ended)
        }
    }
}
