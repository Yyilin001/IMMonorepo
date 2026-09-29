@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import FluentKit
import FluentPostgresDriver
import Foundation
import IMV2Core
import PostgresNIO
import SQLKit
import Testing
@testable import IMV2Server
@testable import IMV2ServerInfrastructure

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["IMV2_RESOURCE_TEST_DATABASE_URL"] != nil))
struct V2ProfileControlBatchPostgresTests {
    @Test("one SQL batch checks 100 viewers independently, including device mismatch and bidirectional blocks")
    func independentAuthorities() async throws {
        try await withFixture(count: 100) { f in
            try await f.sql.raw("INSERT INTO im_v2.user_blocks(blocker_user_id,blocked_user_id,created_at) VALUES(\(bind:f.target.uuidValue!),\(bind:f.identities[1].user),clock_timestamp()),(\(bind:f.identities[7].user),\(bind:f.target.uuidValue!),clock_timestamp())").run()
            try await f.sql.raw("UPDATE im_v2.auth_devices SET revoked_at=clock_timestamp() WHERE device_id=\(bind:f.identities[2].device)").run()
            try await f.sql.raw("UPDATE im_v2.auth_devices SET session_expires_at=clock_timestamp()-INTERVAL '1 second' WHERE device_id=\(bind:f.identities[3].device)").run()
            try await f.sql.raw("INSERT INTO im_v2.account_disables(user_id,operation_id,reason,operator_principal,disabled_at) VALUES(\(bind:f.identities[5].user),\(bind:UUID()),'user_requested','resource-test',clock_timestamp())").run()
            try await f.sql.raw("INSERT INTO im_v2.user_relationships(lower_user_id,higher_user_id,state,requested_by_user_id,updated_at) VALUES(LEAST(\(bind:f.target.uuidValue!),\(bind:f.identities[6].user)),GREATEST(\(bind:f.target.uuidValue!),\(bind:f.identities[6].user)),'accepted',\(bind:f.target.uuidValue!),clock_timestamp())").run()
            let input = f.identities.enumerated().map { index, identity in
                V2ProfileControlRequest(keys: [.init(userID: f.target, context: .relationship)], actor: .init(uuid: identity.user),
                    device: .init(uuid: index == 4 ? f.identities[0].device : identity.device))
            }
            let reader = PostgresV2ProfileControlReader(database: f.database)
            let values = try await reader.read(input, deadline: .now + .seconds(5))
            #expect(values.count == 100)
            for (index, result) in values.enumerated() {
                if [2, 3, 4, 5].contains(index) {
                    #expect(throws: V2MediaStoreError.downloadNotAuthorized) { _ = try result.get() }
                } else {
                    let value = try result.get(), row = try #require(value.rows.first)
                    #expect(value.rows.count == 1)
                    #expect(value.deviceExpiresAt > value.observedAt)
                    #expect(row.relationshipAllowed == (index == 6))
                    #expect(row.view?.userID == ([1, 7].contains(index) ? nil : f.target))
                }
            }
            // A second device belonging to the SAME account must still have its
            // own identity decision, even beside the valid device in one batch.
            let extraDevice = UUID()
            try await f.sql.raw("INSERT INTO im_v2.auth_devices(user_id,device_id,created_at,last_active_at,revoked_at) VALUES(\(bind:f.identities[0].user),\(bind:extraDevice),clock_timestamp(),clock_timestamp(),clock_timestamp())").run()
            let valid = input[0], revoked = V2ProfileControlRequest(keys: valid.keys, actor: valid.actor, device: .init(uuid: extraDevice))
            let devices = try await reader.read([revoked, valid], deadline: .now + .seconds(5))
            #expect(throws: V2MediaStoreError.downloadNotAuthorized) { _ = try devices[0].get() }
            #expect(try devices[1].get().rows.first?.view?.userID == f.target)
        }
    }

    @Test("the production batch owner coalesces different viewers into real PostgreSQL reads")
    func liveCoalescing() async throws {
        try await withFixture(count: 32) { f in
            let batcher = V2ProfileControlBatcher(database: f.database)
            do {
                let accepted = try await withThrowingTaskGroup(of: Bool.self) { group in
                    for identity in f.identities {
                        group.addTask {
                            let request = V2ProfileControlRequest(keys: [.init(userID: f.target, context: .relationship)],
                                actor: .init(uuid: identity.user), device: .init(uuid: identity.device))
                            do {
                                let result = try await batcher.read(request, deadline: .now + .seconds(5))
                                #expect(result.rows.first?.view?.userID == f.target)
                                #expect(result.rows.first?.relationshipAllowed == false)
                                return true
                            } catch V2ResourceProviderError.throttled {
                                // Admission may reject under host contention;
                                // this test does not assert production capacity.
                                return false
                            }
                        }
                    }
                    var count = 0
                    for try await value in group where value { count += 1 }
                    return count
                }
                let state = await batcher.statistics()
                #expect(accepted == state.executedRequests)
                #expect(accepted > state.executedBatches)
                #expect(state.executedKeys == accepted && accepted + state.rejected == 32)
                #expect(state.pendingKeys == 0 && state.inFlightBatches == 0 && state.waiters == 0)
                await batcher.close()
            } catch { await batcher.close(); throw error }
        }
    }

    @Test("closed runtime rejects new reads before the control database is shut down")
    func lifecycle() async throws {
        try await withFixture(count: 1) { f in
            let batcher = V2ProfileControlBatcher(database: f.database)
            await batcher.close()
            let request = V2ProfileControlRequest(keys: [.init(userID: f.target, context: .relationship)],
                actor: .init(uuid: f.identities[0].user), device: .init(uuid: f.identities[0].device))
            await #expect(throws: V2ProfileControlBatchError.closed) { _ = try await batcher.read(request, deadline: .now + .seconds(5)) }
            #expect(await batcher.statistics().executedBatches == 0)
        }
    }

    private func withFixture(count: Int, _ body: (ControlPostgresFixture) async throws -> Void) async throws {
        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(try .postgres(url: #require(ProcessInfo.processInfo.environment["IMV2_RESOURCE_TEST_DATABASE_URL"]),
                maxConnectionsPerEventLoop: 4), as: .psql, isDefault: true)
            let database = resources.database(.psql), sql = try #require(database as? any SQLDatabase)
            let target = UserID(uuid: UUID()), identities = (0..<count).map { _ in ControlTestIdentity(user: UUID(), device: UUID()) }
            let users = identities.map(\.user) + [target.uuidValue!]
            let payload = String(decoding: try JSONEncoder().encode(users), as: UTF8.self)
            try await sql.raw("""
                INSERT INTO im_v2.public_user_profiles(user_id,public_handle,display_name,created_at,updated_at)
                SELECT id::uuid,'cb'||substr(lower(replace(id,'-','')),1,24),'Shared author',clock_timestamp(),clock_timestamp()
                FROM jsonb_array_elements_text(\(bind:payload)::jsonb) value(id)
                """).run()
            let devices = String(decoding: try JSONEncoder().encode(identities), as: UTF8.self)
            try await sql.raw("""
                INSERT INTO im_v2.auth_devices(user_id,device_id,created_at,last_active_at)
                SELECT input.user,input.device,clock_timestamp(),clock_timestamp()
                FROM jsonb_to_recordset(\(bind:devices)::jsonb) input("user" uuid,device uuid)
                """).run()
            try await body(.init(database: database, sql: sql, identities: identities, target: target))
            try await resources.shutdown()
        } catch {
            if let error = error as? PSQLError {
                Issue.record("Control batch SQL: state=\(error.serverInfo?[.sqlState] ?? "unknown"), constraint=\(error.serverInfo?[.constraintName] ?? "none"), message=\(error.serverInfo?[.message] ?? "unknown")")
            }
            try? await resources.shutdown(); throw error
        }
    }
}
private struct ControlTestIdentity: Encodable, Sendable { let user: UUID; let device: UUID }
private struct ControlPostgresFixture: Sendable {
    let database: any Database; let sql: any SQLDatabase
    let identities: [ControlTestIdentity]; let target: UserID
}
