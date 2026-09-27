import FluentKit
import FluentPostgresDriver
import Foundation
import IMV2Core
import SQLKit
import Testing
@testable import IMV2Server

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["IMV2_RESOURCE_TEST_DATABASE_URL"] != nil))
struct V2ResourceProfileBindingPostgresTests {
    @Test("new avatar resources require the complete current generation and a live bind window",
          arguments: ["valid", "expired", "foreign-home", "wrong-usage", "generation", "missing-variant", "retiring", "non-image"])
    func resourceAdmission(scenario: String) async throws {
        try await withFixture { f in
            let media = try await f.media(), before = try await f.store.currentProfile(for: f.actor)
            switch scenario {
            case "expired": try await f.sql.raw("UPDATE im_v2.media_objects SET expires_at=clock_timestamp()-INTERVAL '1 second' WHERE media_id=\(bind:media.uuidValue!)").run()
            case "foreign-home": try await f.sql.raw("UPDATE im_v2.resource_catalog SET home_id=\(bind:UUID()) WHERE media_id=\(bind:media.uuidValue!)").run()
            case "wrong-usage": try await f.sql.raw("UPDATE im_v2.resource_catalog SET home_kind='room',home_id=\(bind:UUID()),usage_kind='message_attachment' WHERE media_id=\(bind:media.uuidValue!)").run()
            case "generation": try await f.sql.raw("UPDATE im_v2.resource_catalog SET generation=2 WHERE media_id=\(bind:media.uuidValue!)").run()
            case "missing-variant": try await f.sql.raw("DELETE FROM im_v2.resource_variants WHERE media_id=\(bind:media.uuidValue!) AND size=256").run()
            case "retiring": try await f.sql.raw("UPDATE im_v2.resource_blob_placements SET state='retiring' WHERE media_id=\(bind:media.uuidValue!)").run()
            case "non-image": try await f.sql.raw("UPDATE im_v2.media_objects SET content_type='application/octet-stream' WHERE media_id=\(bind:media.uuidValue!)").run()
            default: break
            }
            let command = try f.command(before: before, avatar: media)
            if scenario == "valid" {
                guard case .updated(let value) = try await f.store.update(command) else { Issue.record("valid avatar rejected"); return }
                #expect(value.avatar?.mediaID == media)
                #expect(try await f.store.update(command) == .idempotent(value))
                #expect(try await f.count("public_profile_update_operations") == 1)
            } else {
                await #expect(throws: V2ProfileUpdateError.avatarUnavailable) { _ = try await f.store.update(command) }
                #expect(try await f.store.currentProfile(for: f.actor) == before)
                #expect(try await f.count("public_profile_update_operations") == 0)
                #expect(try await f.count("public_profile_update_outbox") == 0)
            }
        }
    }

    @Test("renaming can retain a bound expired avatar; removal protects old capabilities before GC")
    func boundAvatarAndRetirement() async throws {
        try await withFixture { f in
            let media = try await f.media(), before = try await f.store.currentProfile(for: f.actor)
            _ = try await f.store.update(f.command(before: before, avatar: media))
            try await f.sql.raw("UPDATE im_v2.media_objects SET expires_at=clock_timestamp()-INTERVAL '1 second' WHERE media_id=\(bind:media.uuidValue!)").run()
            let bound = try await f.store.currentProfile(for: f.actor)
            let rename = try V2ProfileUpdateCommand(actorUserID: f.actor, operationID: .init(uuid: UUID()), expectedRevision: bound.revision,
                displayName: "Renamed", avatar: .init(mediaID: media))
            guard case .updated(let renamed) = try await f.store.update(rename) else { Issue.record("retained avatar rejected"); return }
            #expect(renamed.avatar?.mediaID == media)
            let retention = PostgresV2MediaRetentionStore(database: f.database)
            _ = try await retention.expireEligibleMedia(now: Date(), withdrawnRetention: 60, limit: 100_000)
            #expect(try await f.state(media) == "available")
            let observed = try #require(try await f.sql.raw("SELECT clock_timestamp() AS value").first(decoding: ProfileBindingDate.self)).value
            let remove = try f.command(before: renamed, avatar: nil)
            // A deliberately old injected application clock must not shorten
            // protection relative to the database's actual binding change.
            let oldClock = PostgresV2ProfileUpdateStore(database: f.database, now: { observed.addingTimeInterval(-600) })
            guard case .updated(let removed) = try await oldClock.update(remove) else { Issue.record("remove rejected"); return }
            #expect(removed.avatar == nil)
            let expiry = try #require(try await f.sql.raw("SELECT expires_at AS value FROM im_v2.media_objects WHERE media_id=\(bind:media.uuidValue!)")
                .first(decoding: ProfileBindingDate.self)).value
            #expect(expiry >= observed.addingTimeInterval(120))
            _ = try await retention.expireEligibleMedia(now: expiry.addingTimeInterval(-0.01), withdrawnRetention: 60, limit: 100_000)
            #expect(try await f.state(media) == "available")
            _ = try await retention.expireEligibleMedia(now: expiry.addingTimeInterval(0.01), withdrawnRetention: 60, limit: 100_000)
            #expect(try await f.state(media) == "expired")
            #expect(try await oldClock.update(remove) == .idempotent(removed))
        }
    }

    @Test("media metadata without a resource catalog entry cannot become an avatar")
    func missingCatalogIsRejected() async throws {
        try await withFixture { f in
            let media = try await f.media(includeCatalog: false), before = try await f.store.currentProfile(for: f.actor)
            try await f.sql.raw("UPDATE im_v2.media_objects SET expires_at=clock_timestamp()-INTERVAL '1 second' WHERE media_id=\(bind:media.uuidValue!)").run()
            let command = try f.command(before: before, avatar: media)
            await #expect(throws: V2ProfileUpdateError.avatarUnavailable) { _ = try await f.store.update(command) }
            #expect(try await f.store.currentProfile(for: f.actor) == before)
        }
    }

    @Test("profile binding rechecks expiration and GC results after a real media lock wait",
          arguments: ["expired-window", "committed-gc", "rolled-back-gc"])
    func bindingAfterMediaLock(scenario: String) async throws {
        try await withFixture { f in
            let media = try await f.media(), before = try await f.store.currentProfile(for: f.actor)
            let command = try f.command(before: before, avatar: media), gate = AvatarMediaLockGate()
            let startedAt = Date()
            let holder = Task {
                try await avatarHeldTransaction(f.database, gate: gate, rollbackAfterRelease: scenario == "rolled-back-gc") { transaction in
                    if scenario == "expired-window" {
                        let sql = try #require(transaction as? any SQLDatabase)
                        try await sql.raw("UPDATE im_v2.media_objects SET expires_at=\(bind:startedAt) WHERE media_id=\(bind:media.uuidValue!)").run()
                    } else {
                        _ = try await PostgresV2MediaRetentionStore(database: transaction)
                            .expireEligibleMedia(now: startedAt.addingTimeInterval(601), withdrawnRetention: 60, limit: 100_000)
                    }
                }
            }
            let pid = try await gate.waitUntilHeld()
            let binding = Task {
                try await PostgresV2ProfileUpdateStore(database: f.database, now: { startedAt.addingTimeInterval(-600) }).update(command)
            }
            do {
                try await requireAvatarLockWait(blocker: pid, sql: f.sql)
                #expect(try await f.state(media) == "available")
                await gate.release()
                if scenario == "rolled-back-gc" {
                    guard case .failure = await holder.result else { Issue.record("GC transaction did not roll back"); _ = await binding.result; return }
                    guard case .updated(let value) = try await binding.value else { Issue.record("rolled back GC blocked a valid avatar"); return }
                    #expect(value.avatar?.mediaID == media)
                    #expect(try await f.count("public_profile_update_operations") == 1)
                } else {
                    try await holder.value
                    await #expect(throws: V2ProfileUpdateError.avatarUnavailable) { _ = try await binding.value }
                    #expect(try await f.store.currentProfile(for: f.actor) == before)
                    #expect(try await f.count("public_profile_update_operations") == 0)
                    #expect(try await f.count("public_profile_update_outbox") == 0)
                }
                #expect(try await f.state(media) == (scenario == "committed-gc" ? "expired" : "available"))
                let purgeCount = try #require(try await f.sql.raw("SELECT count(*) AS value FROM im_v2.media_purge_outbox WHERE media_id=\(bind:media.uuidValue!)")
                    .first(decoding: ProfileBindingCount.self)).value
                #expect(purgeCount == (scenario == "committed-gc" ? 1 : 0))
            } catch { await gate.release(); _ = await holder.result; _ = await binding.result; throw error }
        }
    }

    private func withFixture(_ body: (ProfileBindingFixture) async throws -> Void) async throws {
        let resources = makeV2DatabaseTestResources()
        do {
            // Holder, blocked writer, and lock observer need separate physical
            // connections; a one-connection pool cannot exercise this schedule.
            resources.databases.use(try .postgres(url: #require(ProcessInfo.processInfo.environment["IMV2_RESOURCE_TEST_DATABASE_URL"]),
                maxConnectionsPerEventLoop: 4), as: .psql, isDefault: true)
            let database = resources.database(.psql), sql = try #require(database as? any SQLDatabase), actor = UserID(uuid: UUID())
            let handle = "pb" + actor.rawValue.replacingOccurrences(of: "-", with: "").prefix(24).lowercased()
            try await sql.raw("INSERT INTO im_v2.public_user_profiles(user_id,public_handle,display_name,created_at,updated_at) VALUES(\(bind:actor.uuidValue!),\(bind:handle),'Avatar owner',clock_timestamp(),clock_timestamp())").run()
            try await body(.init(database: database, sql: sql, actor: actor))
            try await resources.shutdown()
        } catch { try? await resources.shutdown(); throw error }
    }
}

private struct ProfileBindingFixture: Sendable {
    let database: any Database, sql: any SQLDatabase
    let actor: UserID
    var store: PostgresV2ProfileUpdateStore { .init(database: database) }
    func command(before: V2ProfileView, avatar: MediaID?) throws -> V2ProfileUpdateCommand {
        try .init(actorUserID: actor, operationID: .init(uuid: UUID()), expectedRevision: before.revision,
            displayName: #require(before.publicIdentity).displayName, avatar: avatar.map { .init(mediaID: $0) })
    }
    func media(includeCatalog: Bool = true) async throws -> MediaID {
        let media = MediaID(uuid: UUID())
        try await sql.raw("""
            INSERT INTO im_v2.media_objects(media_id,owner_user_id,content_type,byte_count,state,upload_session_id,expires_at,state_updated_at,created_at)
            VALUES(\(bind:media.uuidValue!),\(bind:actor.uuidValue!),'image/png',8,'available',\(bind:UUID()),clock_timestamp()+INTERVAL '600 seconds',clock_timestamp(),clock_timestamp())
            """).run()
        if !includeCatalog { return media }
        let reference = try V2StoredObjectReference(placementID: UUID(), binding: .init(id: "profile-binding-adapter", configurationRevision: 1), handle: Data([1]))
        let json = String(decoding: try JSONEncoder().encode(reference), as: UTF8.self), digest = Data(repeating: 1, count: 32)
        try await sql.raw("INSERT INTO im_v2.resource_catalog(media_id,home_kind,home_id,usage_kind,created_at) VALUES(\(bind:media.uuidValue!),'account',\(bind:actor.uuidValue!),'user_avatar',clock_timestamp())").run()
        try await sql.raw("""
            INSERT INTO im_v2.resource_blob_placements(placement_id,media_id,generation,reference_json,byte_count,sha256,state,verified_at)
            VALUES(\(bind:reference.placementID),\(bind:media.uuidValue!),1,\(bind:json)::jsonb,8,\(bind:digest),'active',clock_timestamp())
            """).run()
        for size in [128, 256] {
            try await sql.raw("""
                INSERT INTO im_v2.resource_variants(media_id,generation,recipe,recipe_version,size,reference_json,byte_count,sha256,state,created_at)
                VALUES(\(bind:media.uuidValue!),1,'avatar',1,\(bind:size),\(bind:json)::jsonb,8,\(bind:digest),'ready',clock_timestamp())
                """).run()
        }
        return media
    }
    func count(_ table: String) async throws -> Int64 {
        let actorColumn = table == "public_profile_update_operations" ? "actor_user_id" : "source_user_id"
        return try #require(try await sql.raw("SELECT count(*) AS value FROM im_v2.\(ident:table) WHERE \(ident:actorColumn)=\(bind:actor.uuidValue!)")
            .first(decoding: ProfileBindingCount.self)).value
    }
    func state(_ media: MediaID) async throws -> String? {
        try await sql.raw("SELECT state AS value FROM im_v2.media_objects WHERE media_id=\(bind:media.uuidValue!)").first(decoding: ProfileBindingString.self)?.value
    }
}
private struct ProfileBindingDate: Decodable { let value: Date }
private struct ProfileBindingCount: Decodable { let value: Int64 }
private struct ProfileBindingString: Decodable { let value: String }
