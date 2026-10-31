import Foundation
import GRDB
import IMV2Core
@testable import IMV2ClientKit
import Testing

@Suite("Profile stored version types")
struct V2ProfileStorageTypesTests {
    @Test("profile merges and invalidation cleanup reject REAL versions atomically", arguments:
        ["direct", "cache-revision", "cache-visibility", "save-revision", "save-visibility", "invalidate-view", "invalidate-merge", "clear"],
        [1.5, Double(Int64.max)])
    func invalidVersions(path: String, value: Double) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "profile-storage-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try GRDBV2LocalSyncStore(databaseURL: directory.appending(path: "client.sqlite"), installationBinding: .init(value: UUID()))
        let user = UserID(uuid: UUID()), room = RoomID(uuid: UUID())
        func batch(_ sequence: UInt64, kind: String, payload: [String: Any]) throws -> V2ClientSyncBatch {
            try .init(generation: 1, records: [.init(sequence: sequence, sourceEventID: .init(uuid: UUID()), projectionKind: kind,
                payload: JSONSerialization.data(withJSONObject: payload))], nextSyncToken: .init("profile"),
                receipt: .init("profile"), hasMore: false, capabilityProfile: "base")
        }
        func direct(_ sequence: UInt64, revision: Int) throws -> V2ClientSyncBatch {
            try batch(sequence, kind: "direct_room_profile", payload: ["room_id": room.rawValue, "target_user_id": user.rawValue,
                "public_handle": "profile_user", "display_name": "Original", "account_kind": "regular", "revision": revision,
                "updated_at_ms": 1000, "room_created_at_ms": 1000])
        }
        _ = try await store.apply(direct(1, revision: 1))
        // Seed the durable floor independently of its purge effect so this
        // test can corrupt and validate each retained storage representation.
        try await store.databasePool.write {
            try $0.execute(sql: "INSERT INTO v2_profile_invalidations VALUES (?,2,'hidden',0)", arguments: [user.rawValue])
        }
        let table = path == "direct" ? "v2_direct_room_profile_projections" : ["invalidate-merge", "clear"].contains(path) ? "v2_profile_invalidations" : "v2_profile_views"
        let column = table == "v2_profile_invalidations" ? "minimum_revision" : path.hasSuffix("visibility") ? "visibility_revision" : "revision"
        let before = try await store.cursor()
        try await store.databasePool.write { try $0.execute(sql: "UPDATE \(table) SET \(column) = ?", arguments: [value]) }
        let revision = try #require(V2ProfileRevision(rawValue: 3))
        let profile = try V2ProfileView(userID: user, publicIdentity: .init(userID: user, handle: .init("profile_user"),
            displayName: "Updated", accountKind: .regular), avatar: nil, state: .active, revision: revision, visibilityRevision: revision)
        let incoming = try path.hasPrefix("invalidate")
            ? batch(2, kind: "profile_invalidation", payload: ["user_id": user.rawValue, "minimum_profile_revision": 3, "profile_state": "hidden"])
            : direct(2, revision: 3)
        func perform() async throws {
            if path.hasPrefix("save") || path == "clear" { try await store.saveProfileView(profile) }
            else { _ = try await store.apply(incoming) }
        }
        await #expect(throws: V2ClientSyncError.storageRangeExceeded) { try await perform() }
        #expect(try await store.cursor() == before)
        let after = try await store.databasePool.read { db in
            let raw = try Double.fetchOne(db, sql: "SELECT \(column) FROM \(table)")
            let type = try String.fetchOne(db, sql: "SELECT typeof(\(column)) FROM \(table)")
            let name = try String.fetchOne(db, sql: "SELECT display_name FROM v2_profile_views")
            let directCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM v2_direct_room_profile_projections")
            let pending = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM v2_profile_invalidations")
            return (raw, type, name, directCount, pending)
        }
        #expect(after.0 == value)
        #expect(after.1 == "real")
        #expect(after.2 == "Original")
        #expect(after.3 == 1)
        #expect(after.4 == 1)
        try await store.databasePool.write { try $0.execute(sql: "UPDATE \(table) SET \(column) = ?", arguments: [table == "v2_profile_invalidations" ? 2 : 1]) }
        try await perform()
        if path.hasPrefix("invalidate") {
            let state = try await store.databasePool.read { db in
                let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM v2_direct_room_profile_projections")
                let minimum = try Int64.fetchOne(db, sql: "SELECT minimum_revision FROM v2_profile_invalidations")
                return (count, minimum)
            }
            #expect(state.0 == 0)
            #expect(state.1 == 3)
        } else {
            #expect(try await store.profileView(userID: user)?.revision.rawValue == 3)
            #expect(try await store.databasePool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM v2_profile_invalidations") } == 1)
        }
        try await store.close()
    }
}
