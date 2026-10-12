import FluentKit
import FluentPostgresDriver
import Foundation
import IMV2ActorContracts
@testable import IMV2ServerInfrastructure
import Logging
import PostgresKit
import PostgresNIO
import SQLKit
import Testing

@Suite("Room SQL connection defaults")
struct V2RoomSQLSessionDefaultsTests {
    @Test("Message defaults skip setup SQL; overrides restore after commit/rollback and reconnect",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_ACTOR_TRANSACTION_TEST_DATABASE_IS_DISPOSABLE"] == "1"))
    func connectionDefaultsAndOverrides() async throws {
        let url = try #require(ProcessInfo.processInfo.environment["IMV2_ACTOR_TRANSACTION_DATABASE_URL"])
        let resources = makeV2DatabaseTestResources()
        var configuration = try SQLPostgresConfiguration(url: url)
        configuration.coreConfiguration.options.additionalStartupParameters += V2RoomActivationSQLTimeouts.default.startupParameters
        let host = V2ActorHostIdentity(hostID: .init(uuid: UUID()), incarnationID: UUID())
        let applicationName = V2ActorPostgresSessionIdentity.applicationName(host)
        #expect(applicationName.utf8.count == 37)
        configuration.coreConfiguration.options.additionalStartupParameters.append(("application_name", applicationName))
        resources.databases.use(.postgres(configuration: configuration, maxConnectionsPerEventLoop: 1), as: .psql)
        do {
            let pool = try V2EventLoopDatabasePool(databases: resources.databases,
                logger: Logger(label: "room.defaults.test"), identifier: .psql,
                eventLoops: Array(resources.eventLoopGroup.makeIterator()),
                loanPolicy: .init(maximumConnections: 1, reservedRenewalConnections: 0,
                    maximumQueued: 8, maximumWait: .seconds(2)), sessionTimeouts: .default)
            let database = pool.database
            try await V2PostgresSessionReadiness.verify(database: database, timeouts: .default,
                applicationName: applicationName)
            await #expect(throws: V2PostgresSessionReadinessError.applicationNameMismatch) {
                try await V2PostgresSessionReadiness.verify(database: database, timeouts: .default,
                    applicationName: V2ActorPostgresSessionIdentity.applicationName(
                        .init(hostID: host.hostID, incarnationID: UUID())))
            }
            func sqlCount() -> UInt64 {
                database.loanMetricsSnapshot().observations.values.reduce(0) { sum, source in
                    sum + source.sqlPhases.values.reduce(0) { $0 + $1.count }
                }
            }
            let before = sqlCount()
            let first = try await v2WithRoomActivationTransaction(database: database,
                deadline: .now + .seconds(2)) { try await settings($0) }
            #expect(first.lock == "2s" && first.statement == "10s" && first.idle == "10s")
            #expect(sqlCount() - before == 3) // BEGIN, body SELECT, COMMIT; no setup SELECT.

            let custom = try V2RoomActivationSQLTimeouts(lockMilliseconds: 75,
                statementMilliseconds: 250, idleTransactionMilliseconds: 400)
            let customBefore = sqlCount()
            let overridden = try await v2WithRoomActivationTransaction(database: database,
                deadline: .now + .seconds(2), timeouts: custom) { try await settings($0) }
            #expect(overridden.lock == "75ms" && overridden.statement == "250ms" && overridden.idle == "400ms")
            #expect(sqlCount() - customBefore == 4)

            let afterCommit = try await v2WithRoomActivationTransaction(database: database,
                deadline: .now + .seconds(2)) { try await settings($0) }
            #expect(afterCommit.statement == first.statement && afterCommit.lock == first.lock && afterCommit.idle == first.idle)

            await #expect(throws: ProbeError.rollback) {
                try await v2WithRoomActivationTransaction(database: database,
                    deadline: .now + .seconds(2), timeouts: custom) { borrowed in
                    let value = try await settings(borrowed)
                    #expect(value.statement == "250ms")
                    throw ProbeError.rollback
                }
            }
            let preborrowBefore = sqlCount()
            let restored = try await v2WithOwnerBatchConnection(database: database,
                deadline: .now + .seconds(2), metrics: nil, interrupted: { _ in }) { borrowed, _ in
                try await v2WithRoomActivationTransaction(database: borrowed,
                    deadline: .now + .seconds(2)) { try await settings($0) }
            }
            #expect(sqlCount() - preborrowBefore == 3)
            #expect(restored.pid == first.pid)
            #expect(restored.lock == first.lock && restored.statement == first.statement && restored.idle == first.idle)

            // Closing this test's single physical connection forces a fresh startup packet.
            try await database.withConnection { borrowed in
                let postgres = borrowed as! any PostgresDatabase
                return postgres.withConnection { $0.close() }
            }.get()
            let reconnectBefore = sqlCount()
            let reconnected = try await v2WithRoomActivationTransaction(database: database,
                deadline: .now + .seconds(2)) { try await settings($0) }
            #expect(reconnected.pid != first.pid)
            #expect(reconnected.lock == first.lock && reconnected.statement == first.statement && reconnected.idle == first.idle)
            #expect(sqlCount() - reconnectBefore == 3)
            try await V2PostgresSessionReadiness.verify(database: database, timeouts: .default,
                applicationName: applicationName)
            try await resources.shutdown()
        } catch {
            try? await resources.shutdown()
            throw error
        }
    }
}

private enum ProbeError: Error, Equatable { case rollback }
private struct SessionSettings: Decodable, Sendable {
    let lock: String
    let statement: String
    let idle: String
    let pid: Int
}
private func settings(_ database: any Database) async throws -> SessionSettings {
    let sql = try #require(database as? any SQLDatabase)
    return try #require(try await sql.raw("""
        SELECT current_setting('lock_timeout') AS lock,
               current_setting('statement_timeout') AS statement,
               current_setting('idle_in_transaction_session_timeout') AS idle,
               pg_backend_pid() AS pid
        """).first(decoding: SessionSettings.self))
}
