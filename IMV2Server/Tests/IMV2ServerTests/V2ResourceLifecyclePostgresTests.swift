import Crypto
import FluentKit
import FluentPostgresDriver
import Foundation
import IMV2Core
import SQLKit
import Testing
@testable import IMV2Server

@Suite(.serialized)
struct V2ResourceLifecyclePostgresTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["IMV2_RESOURCE_TEST_DATABASE_URL"] != nil))
    func replayClaimCancellationAndPublicationFence() async throws {
        let address = try #require(ProcessInfo.processInfo.environment["IMV2_RESOURCE_TEST_DATABASE_URL"])
        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(try .postgres(url: address), as: .psql, isDefault: true)
            let database = resources.database(.psql)
            let store = PostgresV2ResourceLifecycleStore(database: database, authorize: { _ in })
            let actor = UUID(), device = UUID(), operation = UUID(), media = UUID()
            let binding = try V2StorageBinding(id: "local-test",configurationRevision: 1)
            let placement = try V2StoredObjectReference(placementID: UUID(),binding: binding,handle: Data("test".utf8))
            let now = Date()
            let row = try await store.create(homeKind: "account",homeID: actor,usageKind: "user_avatar",actor: actor,device: device,operation: operation,mediaID: media,contentType: "text/plain",byteCount: 3,requestJSON: "{\"test\":1}",allocate: { placement },expiresAt: now.addingTimeInterval(300),now: now)
            let replay = try await store.create(homeKind: "account",homeID: actor,usageKind: "user_avatar",actor: actor,device: device,operation: operation,mediaID: media,contentType: "text/plain",byteCount: 3,requestJSON: "{\"test\":1}",allocate: { throw V2ResourceProviderError.unsupportedCapability },expiresAt: now.addingTimeInterval(400),now: now)
            #expect(replay.sessionID == row.sessionID)
            #expect(replay.expiresAt == row.expiresAt)
            await #expect(throws: V2MediaStoreError.idempotencyConflict) {
                _ = try await store.create(homeKind: "account",homeID: actor,usageKind: "user_avatar",actor: actor,device: UUID(),operation: operation,mediaID: media,contentType: "text/plain",byteCount: 3,requestJSON: "{\"test\":1}",allocate: { placement },expiresAt: now.addingTimeInterval(400),now: now)
            }
            let claim = try await store.claimFinalize(session: row.sessionID,generation: 1,actor: actor,device: device,now: now)
            await #expect(throws: V2ResourceProviderError.preconditionFailed) {
                _ = try await store.claimFinalize(session: row.sessionID,generation: 1,actor: actor,device: device,now: now)
            }
            let cancelled = try await store.cancel(session: row.sessionID,generation: 1,actor: actor,device: device,now: now)
            #expect(cancelled.state == "cancelled")
            #expect(cancelled.generation == 2)
            let facts = try V2StoredObjectFacts(reference: placement,byteCount: 3,sha256: Data(SHA256.hash(data: Data([1,2,3]))))
            await #expect(throws: V2ResourceProviderError.preconditionFailed) {
                try await store.publish(claim,facts: facts,actor: actor,device: device,now: now)
            }
            let repeated = try await store.cancel(session: row.sessionID,generation: 1,actor: actor,device: device,now: now)
            #expect(repeated.generation == 2)
            let denied = PostgresV2ResourceLifecycleStore(database: database,authorize: { _ in throw V2MediaStoreError.uploadNotAuthorized })
            await #expect(throws: V2MediaStoreError.uploadNotAuthorized) {
                _ = try await denied.status(session: row.sessionID,actor: actor,device: device)
            }
            try await resources.shutdown()
        } catch { try? await resources.shutdown(); throw error }
    }
}

extension V2ResourceLifecyclePostgresTests {
    @Test("current upload sessions reject invalid clocks without writes and replay committed timestamps",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_RESOURCE_TEST_DATABASE_URL"] != nil))
    func currentUploadClockBounds() async throws {
        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(try .postgres(url: #require(ProcessInfo.processInfo.environment["IMV2_RESOURCE_TEST_DATABASE_URL"])), as: .psql, isDefault: true)
            let database = resources.database(.psql), sql = try #require(database as? any SQLDatabase)
            let store = PostgresV2ResourceLifecycleStore(database: database, authorize: { _ in })
            let actor = UUID(), device = UUID(), operation = UUID(), media = UUID()
            let now = Date(timeIntervalSince1970: 1_750_000_000.1234567)
            let expiry = now.addingTimeInterval(300)
            let binding = try V2StorageBinding(id: "clock-contract", configurationRevision: 1)
            let placement = try V2StoredObjectReference(placementID: UUID(), binding: binding, handle: Data("exact-object".utf8))
            let create: @Sendable (Date, Date) async throws -> V2PersistedResourceUpload = { start, end in
                try await store.create(homeKind: "account", homeID: actor, usageKind: "user_avatar", actor: actor, device: device,
                    operation: operation, mediaID: media, contentType: "text/plain", byteCount: 3, requestJSON: "{\"test\":1}",
                    allocate: { placement }, expiresAt: end, now: start)
            }
            let badDates = [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude, 1e14, -1e14, -1e12]
                .map { Date(timeIntervalSince1970: $0) }
            let empty = try await uploadSnapshot(media: media, sql: sql)
            for invalid in badDates {
                await #expect(throws: V2RoomWriteStoreError.corruptPersistenceState) { _ = try await create(invalid, expiry) }
                await #expect(throws: V2RoomWriteStoreError.corruptPersistenceState) { _ = try await create(now, invalid) }
                #expect(try await uploadSnapshot(media: media, sql: sql) == empty)
            }
            for (start, end) in [(now, now), (now, now.addingTimeInterval(-1)),
                (Date(timeIntervalSince1970: 946_684_800.00000025), Date(timeIntervalSince1970: 946_684_800.00000075))] {
                await #expect(throws: V2RoomWriteStoreError.corruptPersistenceState) { _ = try await create(start, end) }
            }
            #expect(try await uploadSnapshot(media: media, sql: sql) == empty)
            let first = try await create(now, expiry)
            let reread = try await store.status(session: first.sessionID, actor: actor, device: device)
            #expect(first.expiresAt == reread.expiresAt)
            let registered = try await uploadSnapshot(media: media, sql: sql)
            for invalid in badDates {
                let replay = try await create(invalid, invalid)
                #expect(replay.sessionID == first.sessionID && replay.expiresAt == first.expiresAt)
                await #expect(throws: V2RoomWriteStoreError.corruptPersistenceState) {
                    _ = try await store.claimFinalize(session: first.sessionID, generation: 1, actor: actor, device: device, now: invalid)
                }
                await #expect(throws: V2RoomWriteStoreError.corruptPersistenceState) {
                    _ = try await store.cancel(session: first.sessionID, generation: 1, actor: actor, device: device, now: invalid)
                }
                #expect(try await uploadSnapshot(media: media, sql: sql) == registered)
            }
            // Even a finite now must not overflow when computing the claim lease.
            let nearLimit = Date(timeIntervalSince1970: 946_684_800 + 9_223_371_331_200 - 10)
            await #expect(throws: V2RoomWriteStoreError.corruptPersistenceState) {
                _ = try await store.claimFinalize(session: first.sessionID, generation: 1, actor: actor, device: device, now: nearLimit)
            }
            #expect(try await uploadSnapshot(media: media, sql: sql) == registered)
            let claim = try await store.claimFinalize(session: first.sessionID, generation: 1, actor: actor, device: device, now: now)
            let facts = try V2StoredObjectFacts(reference: placement, byteCount: 3, sha256: Data(SHA256.hash(data: Data("abc".utf8))))
            let claimed = try await uploadSnapshot(media: media, sql: sql)
            for invalid in badDates {
                await #expect(throws: V2RoomWriteStoreError.corruptPersistenceState) {
                    try await store.publish(claim, facts: facts, actor: actor, device: device, now: invalid)
                }
                #expect(try await uploadSnapshot(media: media, sql: sql) == claimed)
            }
            try await store.publish(claim, facts: facts, actor: actor, device: device, now: now.addingTimeInterval(1))
            let committed = try await uploadSnapshot(media: media, sql: sql)
            for invalid in badDates {
                #expect(try await store.claimFinalize(session: first.sessionID, generation: 1, actor: actor, device: device, now: invalid).state == "completed")
                #expect(try await uploadSnapshot(media: media, sql: sql) == committed)
            }
            try await resources.shutdown()
        } catch { try? await resources.shutdown(); throw error }
    }

    @Test("cancellation generation exhaustion cannot trap or partially change resource state",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_RESOURCE_TEST_DATABASE_URL"] != nil), arguments: [false, true])
    func cancellationGenerationBounds(alreadyCancelled: Bool) async throws {
        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(try .postgres(url: #require(ProcessInfo.processInfo.environment["IMV2_RESOURCE_TEST_DATABASE_URL"])), as: .psql, isDefault: true)
            let database = resources.database(.psql), sql = try #require(database as? any SQLDatabase)
            let store = PostgresV2ResourceLifecycleStore(database: database, authorize: { _ in })
            let actor = UUID(), device = UUID(), media = UUID(), now = Date()
            let placement = try V2StoredObjectReference(placementID: UUID(), binding: .init(id: "generation-contract", configurationRevision: 1), handle: Data("exact-object".utf8))
            let row = try await store.create(homeKind: "account", homeID: actor, usageKind: "user_avatar", actor: actor, device: device,
                operation: UUID(), mediaID: media, contentType: "text/plain", byteCount: 3, requestJSON: "{}", allocate: { placement },
                expiresAt: now.addingTimeInterval(300), now: now)
            if alreadyCancelled {
                _ = try await store.cancel(session: row.sessionID, generation: 1, actor: actor, device: device, now: now)
            } else {
                try await sql.raw("UPDATE im_v2.resource_upload_sessions SET generation=\(bind: Int64.max) WHERE session_id=\(bind: row.sessionID)").run()
                try await sql.raw("UPDATE im_v2.resource_catalog SET generation=\(bind: Int64.max) WHERE media_id=\(bind: media)").run()
            }
            let before = try await uploadSnapshot(media: media, sql: sql)
            await #expect(throws: V2ResourceProviderError.preconditionFailed) {
                _ = try await store.cancel(session: row.sessionID, generation: Int64.max, actor: actor, device: device, now: now)
            }
            #expect(try await uploadSnapshot(media: media, sql: sql) == before)
            if alreadyCancelled {
                let replay = try await store.cancel(session: row.sessionID, generation: 1, actor: actor, device: device, now: Date(timeIntervalSince1970: .nan))
                #expect(replay.state == "cancelled" && replay.generation == 2)
                #expect(try await uploadSnapshot(media: media, sql: sql) == before)
            }
            try await resources.shutdown()
        } catch { try? await resources.shutdown(); throw error }
    }

    private func uploadSnapshot(media: UUID, sql: any SQLDatabase) async throws -> String {
        struct Snapshot: Decodable { let value: String }
        return try #require(try await sql.raw("""
            SELECT jsonb_build_object(
                'media', (SELECT to_jsonb(r) FROM im_v2.media_objects r WHERE media_id=\(bind: media)),
                'catalog', (SELECT to_jsonb(r) FROM im_v2.resource_catalog r WHERE media_id=\(bind: media)),
                'session', (SELECT to_jsonb(r) FROM im_v2.resource_upload_sessions r WHERE media_id=\(bind: media)),
                'placements', (SELECT jsonb_agg(to_jsonb(r) ORDER BY placement_id) FROM im_v2.resource_blob_placements r WHERE media_id=\(bind: media)),
                'scan', (SELECT to_jsonb(r) FROM im_v2.media_scan_outbox r WHERE media_id=\(bind: media)),
                'purge', (SELECT to_jsonb(r) FROM im_v2.media_purge_outbox r WHERE media_id=\(bind: media))
            )::text AS value
            """).first(decoding: Snapshot.self)).value
    }
}
