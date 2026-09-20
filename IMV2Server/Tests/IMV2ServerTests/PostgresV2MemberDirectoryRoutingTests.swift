import Fluent
import FluentPostgresDriver
import Foundation
import IMV2Core
@testable import IMV2Server
import SQLKit
import Testing
import Vapor

@Suite("Three-database member directory", .serialized)
struct PostgresV2MemberDirectoryRoutingTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE"] == "1"))
    func ownerSwitchHiddenProfilesAndRejoin() async throws {
        let app = try await Application.make(.testing)
        var installed: [DatabaseID] = []
        do {
            let names = ["IMV2_POSTGRES_TEST_CONTROL_DATABASE_URL", "IMV2_POSTGRES_TEST_DATABASE_URL", "IMV2_POSTGRES_TEST_SECONDARY_DATABASE_URL"]
            let urls = try names.map { try #require(ProcessInfo.processInfo.environment[$0]) }
            try #require(Set(urls).count == 3)
            let ids = names.indices.map { DatabaseID(string: "directory-\($0)") }
            for (id, url) in zip(ids, urls) { app.databases.use(try .postgres(url: url, maxConnectionsPerEventLoop: 2), as: id) }
            let databases = ids.map { app.db($0) }
            let sqls = try databases.map { try #require($0 as? any SQLDatabase) }
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let source = try String(contentsOf: root.appending(path: "IMV2/sql/schema.sql"), encoding: .utf8)
            let executable = source.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("--") }.joined(separator: "\n")
            for (id, sql) in zip(ids, sqls) {
                let exists = try await sql.raw("SELECT to_regnamespace('im_v2') IS NOT NULL AS value").first(decoding: DirectoryExists.self)
                try #require(exists?.value == false)
                installed.append(id)
                for statement in postgresStatements(in: executable) where !statement.isEmpty && statement != "BEGIN" && statement != "COMMIT" {
                    try await sql.raw("\(unsafeRaw: statement)").run()
                }
            }
            let control = sqls[0], first = sqls[1], second = sqls[2]
            let room = UUID(), actor = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
            let other = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
            let roomID = RoomID(uuid: room), userID = UserID(uuid: actor)
            for (index, sql) in [first, second].enumerated() {
                let shard = index == 0 ? "owner-a" : "owner-b"
                try await sql.raw("""
                    INSERT INTO im_v2.rooms(room_id,room_shard_id,owner_epoch,membership_revision,room_sequence,log_trimmed_through_room_sequence,capacity_profile_id)
                    VALUES (\(bind: room),\(bind: shard),\(bind: index + 3),7,100,100,'standard')
                    """).run()
                try await sql.raw("""
                    INSERT INTO im_v2.room_memberships(room_id,user_id,joined_revision,role)
                    VALUES (\(bind: room),\(bind: actor),1,'admin'),(\(bind: room),\(bind: other),1,'member')
                    """).run()
                // Stale local profiles must not be used even though their IDs match.
                try await sql.raw("""
                    INSERT INTO im_v2.public_user_profiles(user_id,public_handle,display_name,created_at,updated_at)
                    VALUES (\(bind: actor),'stale_actor','Stale actor',now(),now()),(\(bind: other),'stale_other','Stale other',now(),now())
                    """).run()
            }
            try await control.raw("""
                INSERT INTO im_v2.room_owner_routes(room_id,room_shard_id,route_epoch,created_at,updated_at)
                VALUES (\(bind: room),'owner-a',3,now(),now())
                """).run()
            try await control.raw("""
                INSERT INTO im_v2.public_user_profiles(user_id,public_handle,display_name,state,created_at,updated_at)
                VALUES (\(bind: actor),'current_actor','Current actor','hidden',now(),now()),
                       (\(bind: other),'current_other','Current other','active',now(),now())
                """).run()
            let store = try V2RoutedRoomMembershipDirectoryStore(controlDatabase: databases[0], ownerDatabases: ["owner-a": databases[1], "owner-b": databases[2]])
            func request(_ cursor: String? = nil) throws -> V2RoomMembershipDirectoryRequest {
                try .init(roomID: roomID, actorUserID: userID, cursor: cursor, pageSize: 1)
            }
            let hidden = try await store.list(request())
            #expect(hidden.entries.isEmpty && hidden.actorRole == .admin)
            let oldCursor = try #require(hidden.nextCursor)
            let visible = try await store.list(request(oldCursor))
            #expect(visible.entries.map(\.publicIdentity.displayName) == ["Current other"])
            #expect(visible.nextCursor == nil)
            // Neither first install nor a fully trimmed event log needs old role events.
            for sql in [first, second] {
                #expect(try await sql.raw("SELECT COUNT(*) = 0 AS value FROM im_v2.room_events").first(decoding: DirectoryExists.self)?.value == true)
            }
            try await control.raw("UPDATE im_v2.room_owner_routes SET room_shard_id = 'owner-b', route_epoch = 4 WHERE room_id = \(bind: room)").run()
            await #expect(throws: V2RoomMembershipDirectoryError.ownerChanged) { try await store.list(request(oldCursor)) }
            let newFirst = try await store.list(request())
            let newCursor = try #require(newFirst.nextCursor)
            #expect(newCursor != oldCursor)
            #expect(try await store.list(request(newCursor)).entries.map(\.userID) == [.init(uuid: other)])
            // Control-plane account disable filters the otherwise visible owner member.
            try await control.raw("""
                INSERT INTO im_v2.account_disables(user_id,operation_id,reason,operator_principal,disabled_at)
                VALUES (\(bind: other),\(bind: UUID()),'policy_enforcement','directory-test',now())
                """).run()
            #expect(try await store.list(request(newCursor)).entries.isEmpty)
            // Revocation on the current owner must not fall back to the old active copy.
            try await second.raw("UPDATE im_v2.rooms SET membership_revision = 8 WHERE room_id = \(bind: room)").run()
            try await second.raw("UPDATE im_v2.room_memberships SET left_revision = 8 WHERE room_id = \(bind: room) AND user_id = \(bind: actor)").run()
            await #expect(throws: V2RoomMembershipDirectoryError.actorNotMember) { try await store.list(request()) }
            try await second.raw("UPDATE im_v2.rooms SET membership_revision = 9 WHERE room_id = \(bind: room)").run()
            try await second.raw("INSERT INTO im_v2.room_memberships(room_id,user_id,joined_revision,role) VALUES (\(bind: room),\(bind: actor),9,'member')").run()
            let rejoined = try await store.list(request())
            #expect(rejoined.actorRole == .member && rejoined.membershipRevision == 9)
            await #expect(throws: V2RoomMembershipDirectoryError.revisionConflict(currentRevision: 9)) { try await store.list(request(newCursor)) }
            let interleaved = try V2RoutedRoomMembershipDirectoryStore(
                router: V2PostgresRoomShardRouter(database: databases[0]),
                owners: ["owner-b": PostgresV2RoomMembershipDirectoryStore(database: databases[2])],
                identities: InterleavedDirectoryIdentities(base: PostgresV2MemberDirectoryIdentities(database: databases[0]),
                    beforeReturn: {
                        try await databases[2].transaction { transaction in
                            let sql = try #require(transaction as? any SQLDatabase)
                            try await sql.raw("UPDATE im_v2.rooms SET membership_revision = 10 WHERE room_id = \(bind: room)").run()
                            try await sql.raw("UPDATE im_v2.room_memberships SET left_revision = 10 WHERE room_id = \(bind: room) AND user_id = \(bind: actor) AND left_revision IS NULL").run()
                        }
                    }))
            // Revoke after the owner page has been read, while materializing its
            // control-plane identities. The final owner check must discard it.
            await #expect(throws: V2RoomMembershipDirectoryError.actorNotMember) { try await interleaved.list(request()) }
            // A physical owner that no longer matches the route is rejected independently.
            try await second.raw("UPDATE im_v2.rooms SET owner_epoch = 5 WHERE room_id = \(bind: room)").run()
            await #expect(throws: V2RoomMembershipDirectoryError.ownerChanged) { try await store.list(request()) }
            for id in installed { try await (app.db(id) as! any SQLDatabase).raw("DROP SCHEMA im_v2 CASCADE").run() }
            installed = []
            try await app.asyncShutdown()
        } catch {
            for id in installed { if let sql = app.db(id) as? any SQLDatabase { try? await sql.raw("DROP SCHEMA IF EXISTS im_v2 CASCADE").run() } }
            try? await app.asyncShutdown()
            throw error
        }
    }
}
private struct DirectoryExists: Decodable { let value: Bool }

private struct InterleavedDirectoryIdentities: V2MemberDirectoryIdentityReading {
    let base: PostgresV2MemberDirectoryIdentities
    let beforeReturn: @Sendable () async throws -> Void
    func identities(for users: [UserID]) async throws -> [UserID: V2PublicIdentity] {
        let result = try await base.identities(for: users)
        try await beforeReturn()
        return result
    }
}
