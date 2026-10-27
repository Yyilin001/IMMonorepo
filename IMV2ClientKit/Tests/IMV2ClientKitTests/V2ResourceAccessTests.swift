import Foundation
import GRDB
import IMV2Core
@testable import IMV2ClientKit
import Testing

struct V2ResourceAccessTests {
    private func fixture() throws -> (GRDBV2LocalSyncStore, URL, RoomID, V2RoomResourcePage) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("resource-access-\(UUID())")
        let store = try GRDBV2LocalSyncStore(databaseURL: directory.appendingPathComponent("V2.sqlite"), installationBinding: .init(value: UUID()), userID: .init(uuid: UUID()))
        let room = RoomID(uuid: UUID()), media = MediaID(uuid: UUID())
        let item = try V2RoomResourceItem(messageID: .init(uuid: UUID()), messageRevision: 1,
            position: .init(roomSequence: 9, ordinal: 0, mediaID: media), createdAt: 1000,
            descriptor: .init(key: .init(home: .room(room), mediaID: media), revision: 1,
                displayName: .init("private.jpg"), contentType: "image/jpeg", byteCount: 32,
                checksum: .init(value: String(repeating: "a", count: 64)), state: .ready))
        return (store,directory,room,try .init(items: [item], snapshotUpperRoomSequence: 10, nextCursor: nil))
    }

    @Test func membershipChangeRejectsInflightPageAndHidesExistingMetadata() async throws {
        let (store,directory,room,page) = try fixture()
        let first = try await store.beginResourceDirectoryScan(roomID: room, query: .init())
        try await store.applyResourceDirectoryPage(page, to: first)
        #expect(try await store.resourceDirectory().entries.count == 1)
        let pending = try await store.beginResourceDirectoryScan(roomID: room, query: .init())
        try await store.databasePool.write { db in
            try db.execute(sql: "INSERT INTO v2_room_membership_states(room_id,membership_revision,source_event_id,is_member) VALUES(?,1,?,0)", arguments: [room.rawValue,UUID().uuidString])
        }
        #expect(try await store.resourceDirectory().entries.isEmpty)
        #expect(try await store.resourceDirectoryScan(roomID: room) == nil)
        await #expect(throws: V2ResourceStorageError.conflict) { try await store.applyResourceDirectoryPage(page, to: pending) }
        let item = try #require(page.items.first)
        try await store.indexResource(item.descriptor, reference: .message(.init(roomID: room, messageID: item.messageID), ordinal: 0), businessRevision: 2)
        #expect(try await store.resourceDirectory().entries.isEmpty)
        try await store.close(); try FileManager.default.removeItem(at: directory)
    }

    @Test func denialInvalidatesOtherFiltersAndFreshAuthorityCanRestoreDirectory() async throws {
        let (store,directory,room,page) = try fixture()
        let first = try await store.beginResourceDirectoryScan(roomID: room, query: .init())
        try await store.applyResourceDirectoryPage(page, to: first)
        let old = try await store.beginResourceDirectoryScan(roomID: room, query: .init(category: .image))
        let denied = try await store.beginResourceDirectoryScan(roomID: room, query: .init())
        try await store.denyResourceDirectory(scan: denied)
        #expect(try await store.resourceDirectory().entries.isEmpty)
        await #expect(throws: V2ResourceStorageError.conflict) { try await store.applyResourceDirectoryPage(page, to: old) }
        let fresh = try await store.beginResourceDirectoryScan(roomID: room, query: .init())
        try await store.applyResourceDirectoryPage(page, to: fresh)
        #expect(try await store.resourceDirectory().entries.count == 1)
        try await store.close(); try FileManager.default.removeItem(at: directory)
    }

    @Test func snapshotActivationRotatesAccessAndRestoresTriggersOnTheNewLiveBank() async throws {
        let (store,directory,room,page) = try fixture()
        let prior = try await store.beginResourceDirectoryScan(roomID: room, query: .init())
        let reset = try V2ClientResetRequired(snapshotID: .init(uuid: UUID()), generation: 2, baseSequence: 10, expiresAt: .distantFuture)
        let fixture = try makeSnapshotFixture(reset: reset, pages: [])
        try await store.beginReset(reset)
        try await store.beginSnapshotImport(fixture.manifest, initialDigest: V2SnapshotV3Digest.initial(baseSequence: 10, capabilityProfile: "base"))
        try await store.prepareSnapshotActivation(fixture.manifest)
        try await store.activateAcknowledgedSnapshot(fixture.manifest)
        await #expect(throws: V2ResourceStorageError.conflict) { try await store.applyResourceDirectoryPage(page, to: prior) }
        let after = try await store.beginResourceDirectoryScan(roomID: room, query: .init())
        try await store.databasePool.write { db in
            try db.execute(sql: "INSERT INTO v2_room_membership_states(room_id,membership_revision,source_event_id,is_member) VALUES(?,1,?,0)", arguments: [room.rawValue,UUID().uuidString])
        }
        await #expect(throws: V2ResourceStorageError.conflict) { try await store.applyResourceDirectoryPage(page, to: after) }
        #expect(try await store.resourceDirectory().entries.isEmpty)
        try await store.close(); try FileManager.default.removeItem(at: directory)
    }
}
