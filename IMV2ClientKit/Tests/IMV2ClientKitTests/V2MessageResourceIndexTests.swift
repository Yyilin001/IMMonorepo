import Foundation
import GRDB
import IMV2Core
import Testing
@testable import IMV2ClientKit

@Suite("Message and snapshot resource indexing", .timeLimit(.minutes(1)))
struct V2MessageResourceIndexTests {
    @Test func acceptanceIndexesMetadataAndCursorInOneCommitAndDeduplicatesSources() async throws {
        let f = try Fixture(), resource = try f.resource(name: "收到的图片.png")
        try await f.accept(resources: [resource])
        let first = try await f.store.resourceDirectory()
        #expect(first.entries.map(\.descriptor) == [resource])
        #expect(first.entries.first?.referenceCount == 1)
        #expect(try await f.store.cursor()?.appliedSequence == 1)
        try await f.accept(id: .init(uuid: UUID()), sequence: 2, resources: [resource])
        #expect(try await f.store.resourceDirectory().entries.count == 1)
        #expect(try await f.store.resourceDirectory().entries.first?.referenceCount == 2)
        try await f.remove()
    }

    @Test(arguments: ["missing", "wrongRoom", "wrongBytes", "wrongMedia"])
    func invalidDescriptorRollsBackMessageAndSyncCursor(mode: String) async throws {
        let f = try Fixture(), resource = try f.resource()
        var body = try f.body(resources: [resource])
        var items = try #require(body["media_presentations"] as? [[String: Any]])
        switch mode {
        case "missing": items[0]["resource_descriptor"] = nil
        case "wrongRoom": items[0]["resource_descriptor"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(resourceDescriptorFixture(room: UUID().uuidString, media: resource.key.mediaID.rawValue, contentType: resource.contentType, bytes: resource.byteCount)))
        case "wrongMedia": items[0]["media_id"] = UUID().uuidString
        default: items[0]["byte_count"] = 999
        }
        body["media_presentations"] = items
        let record = try f.record(body, sequence: 1)
        await #expect(throws: V2ClientProjectionError.invalidMessagePayload) { try await f.apply(record) }
        #expect(try await f.store.messages(in: f.room).isEmpty)
        #expect(try await f.store.resourceDirectory().entries.isEmpty)
        #expect(try await f.store.cursor() == nil)
        try await f.remove()
    }

    @Test func catalogConflictRollsBackEveryAttachmentAndTheAcceptedMessage() async throws {
        let f = try Fixture(), existing = try f.resource(name: "original.png"), incoming = try f.resource(name: "new.png")
        try await f.store.indexResource(existing, reference: .message(.init(roomID: f.room, messageID: .init(uuid: UUID())), ordinal: 0), businessRevision: 1)
        let conflict = try V2ResourceDescriptor(key: existing.key, revision: existing.revision, displayName: .init("conflict.png"),
            contentType: existing.contentType, byteCount: existing.byteCount, checksum: existing.checksum, state: .ready)
        let record = try f.record(f.body(resources: [incoming,conflict]), sequence: 1)
        await #expect(throws: V2ResourceStorageError.conflict) { try await f.apply(record) }
        #expect(try await f.store.messages(in: f.room).isEmpty)
        #expect(try await f.store.cursor() == nil)
        #expect(try await f.store.resourceDirectory().entries.map(\.descriptor) == [existing])
        try await f.remove()
    }

    @Test func replacementReordersAndRemovesReferencesThenWithdrawalPreventsLateResurrection() async throws {
        let f = try Fixture(), first = try f.resource(name: "first.png"), second = try f.resource(name: "second.png")
        try await f.accept(resources: [first,second])
        let state = try f.body(resources: [second], revision: 2)
        let edit = try f.record(["event_type": "message.edited", "room_id": f.room.rawValue, "message_id": f.message.rawValue,
            "room_sequence": 2, "message_revision": 2, "text": "附件", "entities": [],
            "replacement": ["schema_version": 1, "accepted_event_id": f.origin.rawValue,
                "accepted_membership_revision": 0, "state": state]], sequence: 2, origin: .init(uuid: UUID()))
        try await f.apply(edit)
        #expect(try await f.store.resourceDirectory().entries.map(\.descriptor.key) == [second.key])
        #expect(try await f.store.resourceDirectory().entries.first?.referenceCount == 1)
        try await f.store.indexResource(first, reference: .message(.init(roomID: f.room, messageID: f.message), ordinal: 0), businessRevision: 1)
        #expect(try await f.store.resourceDirectory().entries.map(\.descriptor.key) == [second.key])
        let removal = try f.record(["event_type": "message.withdrawn", "room_id": f.room.rawValue,
            "message_id": f.message.rawValue, "message_revision": 3], sequence: 3, origin: .init(uuid: UUID()))
        try await f.apply(removal)
        #expect(try await f.store.resourceDirectory().entries.isEmpty)
        try await f.store.indexResource(second, reference: .message(.init(roomID: f.room, messageID: f.message), ordinal: 0), businessRevision: 2)
        #expect(try await f.store.resourceDirectory().entries.isEmpty)
        try await f.remove()
    }

    @Test func snapshotMetadataStaysInvisibleUntilActivationAndDurableIndexResumesInBoundedBatches() async throws {
        let f = try Fixture(), first = try f.resource(name: "snapshot-a.png"), second = try f.resource(name: "snapshot-b.png")
        let fixtures = try f.snapshot(resources: [first,second])
        try await f.importSnapshot(fixtures)
        #expect(try await f.store.resourceDirectory().entries.isEmpty)
        #expect(try await f.store.resourceDirectory().isIndexing == false)
        try await f.store.prepareSnapshotActivation(fixtures.manifest)
        #expect(try await f.store.resourceDirectory().entries.isEmpty)
        try await f.store.activateAcknowledgedSnapshot(fixtures.manifest)
        #expect(try await f.store.resourceDirectory().isIndexing)
        #expect(try await f.store.indexResourceProjectionBatch(limit: 1))
        #expect(try await f.store.resourceDirectory().entries.count == 1)
        try await f.store.close()
        let restored = try GRDBV2LocalSyncStore(databaseURL: f.database, installationBinding: f.binding, userID: f.user)
        #expect(try await restored.resourceDirectory().isIndexing)
        #expect(try await restored.indexResourceProjectionBatch(limit: 1) == false)
        #expect(Set(try await restored.resourceDirectory().entries.map(\.descriptor)) == Set([first,second]))
        #expect(try await restored.resourceDirectory().isIndexing == false)
        try await restored.cleanupRetiredSnapshotTables()
        try await restored.close(); try FileManager.default.removeItem(at: f.root)
    }

    @Test(arguments: [false, true])
    func snapshotResourceSchemaAcceptsLiveBanksAndRejectsChangedIndex(_ cleanupBeforeReopen: Bool) async throws {
        let f = try Fixture(), resource = try f.resource(name: "schema-bank.png")
        defer { try? FileManager.default.removeItem(at: f.root) }
        let snapshot = try f.snapshot(resources: [resource])
        try await f.importSnapshot(snapshot)
        try await f.store.prepareSnapshotActivation(snapshot.manifest)
        try await f.store.activateAcknowledgedSnapshot(snapshot.manifest)
        if cleanupBeforeReopen { try await f.store.cleanupRetiredSnapshotTables() }
        try await f.store.close()
        let readonly = try GRDBV2LocalSyncStore(localReadOnlyDatabaseURL: f.database, installationBinding: f.binding, userID: f.user)
        try await readonly.close()
        let reopened = try GRDBV2LocalSyncStore(databaseURL: f.database, installationBinding: f.binding, userID: f.user)
        let suffix = snapshot.manifest.reset.snapshotID.rawValue.replacingOccurrences(of: "-", with: "")
        let index = "v2_snapshot_\(suffix)_resource_projection_index_jobs_0_idx"
        try await reopened.databasePool.write { db in
            try db.execute(sql: "DROP INDEX \(index)")
            try db.execute(sql: "CREATE INDEX \(index) ON v2_resource_projection_index_jobs(message_id)")
        }
        try await reopened.close()
        await #expect(throws: V2ClientLocalStorageError.unsupportedResourceSchema) {
            let wrong = try GRDBV2LocalSyncStore(databaseURL: f.database, installationBinding: f.binding, userID: f.user)
            try await wrong.close()
        }
        await #expect(throws: V2ClientLocalStorageError.unsupportedResourceSchema) {
            let wrong = try GRDBV2LocalSyncStore(localReadOnlyDatabaseURL: f.database, installationBinding: f.binding, userID: f.user)
            try await wrong.close()
        }
    }

    @Test func oldQueryOnlyReferenceNeedsNewSnapshotAuthorityAndEqualRevisionCanRevalidate() async throws {
        let f = try Fixture(), resource = try f.resource()
        let reference = V2ResourceReferenceContext.message(.init(roomID: f.room, messageID: f.message), ordinal: 0)
        try await f.store.indexResource(resource, reference: reference, businessRevision: 1)
        #expect(try await f.store.resourceDirectory().entries.count == 1)
        let snapshot = try f.snapshot(resources: [])
        try await f.importSnapshot(snapshot)
        try await f.store.prepareSnapshotActivation(snapshot.manifest)
        try await f.store.activateAcknowledgedSnapshot(snapshot.manifest)
        #expect(try await f.store.resourceDirectory().entries.isEmpty)
        // This is the same trusted directory transaction used by a fresh,
        // post-snapshot server page, including unchanged business revisions.
        try await f.store.indexResource(resource, reference: reference, businessRevision: 1)
        #expect(try await f.store.resourceDirectory().entries.map(\.descriptor) == [resource])
        try await f.remove()
    }

    @Test func resourceCenterDrainsSnapshotQueueAndPublishesIndexedDirectory() async throws {
        let f = try Fixture(), resource = try f.resource()
        let snapshot = try f.snapshot(resources: [resource])
        try await f.importSnapshot(snapshot)
        try await f.store.prepareSnapshotActivation(snapshot.manifest)
        try await f.store.activateAcknowledgedSnapshot(snapshot.manifest)
        let center = try await V2ResourceCenter.make(scope: .init(incarnation: UUID(), accountID: f.user,
            directory: f.root.appending(path: "account"), cacheDirectory: f.root.appending(path: "cache")), store: f.store)
        let snapshots = try await center.snapshots(for: .init())
        for await value in snapshots {
            if case .available(let page) = value, !page.isIndexing {
                #expect(page.entries.map(\.descriptor) == [resource]); break
            }
        }
        await center.close(); try await f.remove()
    }

    private struct Fixture {
        let root: URL, database: URL
        let binding = V2LocalInstallationBinding(value: UUID()), user = UserID(uuid: UUID())
        let room = RoomID(uuid: UUID()), message = MessageID(uuid: UUID()), origin = EventID(uuid: UUID())
        let store: GRDBV2LocalSyncStore
        init() throws {
            root = FileManager.default.temporaryDirectory.appending(path: "message-resource-index-\(UUID())")
            database = root.appending(path: "V2.sqlite")
            store = try .init(databaseURL: database, installationBinding: binding, userID: user)
        }
        func resource(name: String = "file.png") throws -> V2ResourceDescriptor {
            try resourceDescriptorFixture(room: room.rawValue, media: UUID().uuidString, contentType: "image/png", bytes: 42, name: name)
        }
        func body(id: MessageID? = nil, resources: [V2ResourceDescriptor], revision: UInt64 = 1) throws -> [String: Any] {
            ["event_type": "message.accepted", "message_id": (id ?? message).rawValue, "room_id": room.rawValue,
                "room_sequence": 1, "timeline_sequence": 1, "message_revision": revision, "sender_user_id": user.rawValue,
                "text": "附件", "media_ids": resources.map { $0.key.mediaID.rawValue },
                "media_presentations": try resources.map { try resourcePresentationWireFixture(room: room.rawValue, media: $0.key.mediaID.rawValue,
                    contentType: $0.contentType, bytes: $0.byteCount, descriptor: $0) },
                "mention_user_ids": [], "mentions_everyone": false, "entities": [],
                "reply_to_message_id": NSNull(), "forwarded_from_message_id": NSNull(), "forwarded_from_user_id": NSNull(),
                "server_created_at_ms": 1750000000000]
        }
        func record(_ body: [String: Any], sequence: UInt64, origin event: EventID? = nil) throws -> V2ClientSyncRecord {
            try .init(sequence: sequence, sourceEventID: event ?? origin, projectionKind: "message", payload: JSONSerialization.data(withJSONObject: body))
        }
        func apply(_ record: V2ClientSyncRecord) async throws {
            _ = try await store.apply(.init(generation: 1, records: [record], nextSyncToken: .init("index-\(record.sequence)"), receipt: .init("index-\(record.sequence)"), hasMore: false, capabilityProfile: "base"))
        }
        func accept(id: MessageID? = nil, sequence: UInt64 = 1, resources: [V2ResourceDescriptor]) async throws {
            var payload = try body(id: id, resources: resources)
            payload["room_sequence"] = sequence; payload["timeline_sequence"] = sequence
            try await apply(record(payload, sequence: sequence, origin: sequence == 1 ? origin : .init(uuid: UUID())))
        }
        func snapshot(resources: [V2ResourceDescriptor]) throws -> SnapshotFixture {
            let reset = try V2ClientResetRequired(snapshotID: .init(uuid: UUID()), generation: 2, baseSequence: 10, expiresAt: .distantFuture)
            let items = try resources.enumerated().map { offset, descriptor in
                let id = MessageID(uuid: UUID())
                var payload = try body(id: id, resources: [descriptor])
                payload["room_sequence"] = offset + 1; payload["timeline_sequence"] = offset + 1
                return try V2SnapshotProjectionItem(key: .init(projectionKind: "message", entityKey: id.rawValue), sourceEventID: .init(uuid: UUID()), sequence: UInt64(offset + 1), payload: JSONSerialization.data(withJSONObject: payload))
            }.sorted { $0.key < $1.key }
            return try makeSnapshotFixture(reset: reset, pages: items.isEmpty ? [] : [.init(items: items)])
        }
        func importSnapshot(_ fixture: SnapshotFixture) async throws {
            try await store.beginReset(fixture.manifest.reset)
            try await store.beginSnapshotImport(fixture.manifest, initialDigest: V2SnapshotV3Digest.initial(baseSequence: 10, capabilityProfile: "base"))
            for page in fixture.pages { try await store.applySnapshotPage(page, for: fixture.manifest) }
        }
        func remove() async throws { try await store.close(); try FileManager.default.removeItem(at: root) }
    }
}
