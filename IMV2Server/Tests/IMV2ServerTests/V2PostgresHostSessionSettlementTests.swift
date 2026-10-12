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

@Suite("Excluded Host database settlement")
struct V2PostgresHostSessionSettlementTests {
    @Test("Waits for old backend exit and rollback while preserving another incarnation",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_ACTOR_TRANSACTION_TEST_DATABASE_IS_DISPOSABLE"] == "1"))
    func excludedHostDatabaseSettlement() async throws {
        let url = try #require(ProcessInfo.processInfo.environment["IMV2_ACTOR_TRANSACTION_DATABASE_URL"])
        let resources = makeV2DatabaseTestResources()
        let logger = Logger(label: "imv2.host.settlement.test")
        let old = V2ActorHostIdentity(hostID: .init(uuid: UUID()), incarnationID: UUID())
        let successor = V2ActorHostIdentity(hostID: old.hostID, incarnationID: UUID())
        resources.databases.use(try .postgres(url: url, maxConnectionsPerEventLoop: 1), as: .psql)
        let database = try V2EventLoopBalancedDatabase(databases: [resources.database(.psql)],
            loanPolicy: .init(maximumConnections: 1, reservedRenewalConnections: 0,
                maximumQueued: 8, maximumWait: .seconds(2)))
        var configuration = try SQLPostgresConfiguration(url: url).coreConfiguration
        configuration.options.additionalStartupParameters.append(
            ("application_name", V2ActorPostgresSessionIdentity.applicationName(old)))
        // Direct connections never create a replacement when terminated. The
        // test stops issuing old-incarnation work before invoking settlement.
        let target = try await PostgresConnection.connect(on: resources.eventLoopGroup.next(),
            configuration: configuration, id: 1, logger: logger).get()
        configuration.options.additionalStartupParameters = [
            ("application_name", V2ActorPostgresSessionIdentity.applicationName(successor))]
        let healthy = try await PostgresConnection.connect(on: resources.eventLoopGroup.next(),
            configuration: configuration, id: 2, logger: logger).get()
        do {
            let sql = try #require(database as? any SQLDatabase)
            try await sql.raw("CREATE TABLE imv2_host_settlement_probe (id integer PRIMARY KEY)").run()
            _ = try await target.query("BEGIN", logger: logger).get()
            _ = try await target.query("INSERT INTO imv2_host_settlement_probe VALUES (1)", logger: logger).get()
            _ = try await target.query("SELECT pg_advisory_xact_lock(884477)", logger: logger).get()
            let locked = try #require(try await sql.raw(
                "SELECT pg_try_advisory_xact_lock(884477) AS acquired").first(decoding: LockResult.self))
            #expect(!locked.acquired)
            try await V2PostgresHostSessionSettlement.settle(host: old, database: database,
                deadline: .now + .seconds(3))
            let rows = try #require(try await sql.raw(
                "SELECT count(*)::integer AS count FROM imv2_host_settlement_probe").first(decoding: RowCount.self))
            #expect(rows.count == 0)
            let released = try #require(try await sql.raw(
                "SELECT pg_try_advisory_xact_lock(884477) AS acquired").first(decoding: LockResult.self))
            #expect(released.acquired)
            let alive = try await healthy.query("SELECT 1", logger: logger).get()
            #expect(try alive.rows[0].decode(Int.self) == 1)
            try await V2PostgresHostSessionSettlement.settle(host: old, database: database,
                deadline: .now + .seconds(3))
            try await sql.raw("DROP TABLE imv2_host_settlement_probe").run()
            try? await target.close().get()
            try await healthy.close().get()
            try await resources.shutdown()
        } catch {
            try? await target.close().get()
            try? await healthy.close().get()
            try? await resources.shutdown()
            throw error
        }
    }
}

private struct LockResult: Decodable { let acquired: Bool }
private struct RowCount: Decodable { let count: Int }
