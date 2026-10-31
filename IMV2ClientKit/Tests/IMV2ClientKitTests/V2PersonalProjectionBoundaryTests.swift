import Foundation
import GRDB
import IMV2Core
@testable import IMV2ClientKit
import Testing

@Suite("Personal synchronization excludes public room projections")
struct V2PersonalProjectionBoundaryTests {
    @Test(arguments: ["message", "message_reaction", "group_capability", "moderation"])
    func incrementalBatchRejectsPublicContentAtomically(kind: String) async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        do {
            let valid = try fixture.aliasRecord(sequence: 1)
            let invalid = try V2ClientSyncRecord(sequence: 2, sourceEventID: .init(uuid: UUID()),
                projectionKind: kind, payload: Data("{}".utf8))
            let before = try await fixture.store.cursor()
            await #expect(throws: V2ClientSyncError.unexpectedPersonalProjection(kind)) {
                _ = try await fixture.store.apply(fixture.batch([valid, invalid]))
            }
            #expect(try await fixture.store.cursor() == before)
            #expect(try await fixture.store.events().isEmpty)
            #expect(try await fixture.aliasRevision() == nil)
            _ = try await fixture.store.apply(fixture.batch([valid]))
            #expect(try await fixture.store.events() == [valid])
            #expect(try await fixture.store.cursor()?.appliedSequence == 1)
            #expect(try await fixture.aliasRevision() == 1)
            try await fixture.store.close()
        } catch { try? await fixture.store.close(); throw error }
    }

    @Test(arguments: ["message", "message_reaction", "group_capability", "moderation"])
    func snapshotPageRejectsPublicContentWithoutAdvancingImport(kind: String) async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        do {
            let valid = try fixture.aliasRecord(sequence: 1)
            let validItem = try V2SnapshotProjectionItem(
                key: .init(projectionKind: valid.projectionKind, entityKey: fixture.target.rawValue),
                sourceEventID: valid.sourceEventID, sequence: 1, payload: valid.payload)
            let invalidItem = try V2SnapshotProjectionItem(key: .init(projectionKind: kind, entityKey: "public"),
                sourceEventID: .init(uuid: UUID()), sequence: 2, payload: Data("{}".utf8))
            let reset = try V2ClientResetRequired(snapshotID: .init(uuid: UUID()), generation: 2,
                baseSequence: 2, expiresAt: .distantFuture)
            // contact_alias sorts before every rejected kind: a partial shadow
            // write must roll back when the later public item is rejected.
            let bad = try makeSnapshotFixture(reset: reset, pages: [.init(items: [validItem, invalidItem])])
            let initial = V2SnapshotV3Digest.initial(baseSequence: 2, capabilityProfile: "base")
            try await fixture.store.beginReset(reset)
            try await fixture.store.beginSnapshotImport(bad.manifest, initialDigest: initial)
            let before = try await fixture.store.cursor()
            await #expect(throws: V2ClientSyncError.unexpectedPersonalProjection(kind)) {
                try await fixture.store.applySnapshotPage(bad.pages[0], for: bad.manifest)
            }
            #expect(try await fixture.store.cursor() == before)
            #expect(try await fixture.store.nextSnapshotPageIndex(for: bad.manifest) == 0)
            let pool = await fixture.store.databasePool
            try await pool.read { db in
                let state = try #require(try Row.fetchOne(db, sql: "SELECT * FROM v2_snapshot_import"))
                #expect(state["rolling_digest"] as String == initial)
                #expect(state["applied_items"] as Int == 0)
                #expect(state["applied_bytes"] as Int == 0)
                let table = GRDBV2LocalSyncStore.ProjectionTableTarget.snapshotShadow.table("v2_contact_alias_invalidations")
                #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM \(table)") == 0)
            }
            #expect(try await fixture.aliasRevision() == nil)
            // A rejected artifact cannot be silently changed in place. End
            // this reset, then activate a fresh valid personal snapshot.
            try await fixture.store.cancelReset(reset)
            let replacement = try V2ClientResetRequired(snapshotID: .init(uuid: UUID()), generation: 2,
                baseSequence: 2, expiresAt: .distantFuture)
            let good = try makeSnapshotFixture(reset: replacement, pages: [.init(items: [validItem])])
            try await fixture.store.beginReset(replacement)
            try await fixture.store.beginSnapshotImport(good.manifest, initialDigest: initial)
            try await fixture.store.applySnapshotPage(good.pages[0], for: good.manifest)
            try await fixture.store.prepareSnapshotActivation(good.manifest)
            try await fixture.store.activateAcknowledgedSnapshot(good.manifest)
            #expect(try await fixture.aliasRevision() == 1)
            #expect(try await fixture.store.cursor()?.appliedSequence == 2)
            try await fixture.store.close()
        } catch { try? await fixture.store.close(); throw error }
    }

    private struct Fixture {
        let directory: URL
        let store: GRDBV2LocalSyncStore
        let target = UserID(uuid: UUID())
        init() throws {
            directory = FileManager.default.temporaryDirectory.appending(path: "personal-projection-boundary-\(UUID())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            store = try .init(databaseURL: directory.appending(path: "state.sqlite"),
                installationBinding: .init(value: UUID()))
        }
        func aliasRecord(sequence: UInt64) throws -> V2ClientSyncRecord {
            try .init(sequence: sequence, sourceEventID: .init(uuid: UUID()), projectionKind: "contact_alias",
                payload: JSONSerialization.data(withJSONObject: ["target_user_id": target.rawValue, "revision": 1]))
        }
        func batch(_ records: [V2ClientSyncRecord]) throws -> V2ClientSyncBatch {
            try .init(generation: 1, records: records, nextSyncToken: .init("next"), receipt: .init("receipt"),
                hasMore: false, capabilityProfile: "base")
        }
        func aliasRevision() async throws -> Int64? {
            try await store.databasePool.read { db in
                try Int64.fetchOne(db, sql: "SELECT revision FROM v2_contact_alias_invalidations WHERE target_user_id = ?",
                    arguments: [target.rawValue])
            }
        }
    }
}
