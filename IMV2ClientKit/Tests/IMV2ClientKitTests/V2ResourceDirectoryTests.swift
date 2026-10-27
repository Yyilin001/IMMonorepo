import Foundation
import IMV2Core
@testable import IMV2ClientKit
import Testing

@Suite("Local resource directory")
struct V2ResourceDirectoryTests {
    private func store() throws -> (GRDBV2LocalSyncStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("resource-directory-\(UUID())")
        return (try GRDBV2LocalSyncStore(databaseURL: directory.appendingPathComponent("V2.sqlite"),
            installationBinding: .init(value: UUID()), userID: .init(uuid: UUID())), directory)
    }

    private func descriptor(room: RoomID, media: MediaID = .init(uuid: UUID()), name: String = "photo.jpg", revision: Int64 = 1) throws -> V2ResourceDescriptor {
        try .init(key: .init(home: .room(room), mediaID: media), revision: revision, displayName: .init(name),
            contentType: "image/jpeg", byteCount: 32, checksum: .init(value: String(repeating: "a", count: 64)), state: .ready)
    }

    @Test func referencesDeduplicateAndRevocationDoesNotResurrect() async throws {
        let (store, directory) = try store(), room = RoomID(uuid: UUID())
        let resource = try descriptor(room: room)
        let first = V2ResourceReferenceContext.message(.init(roomID: room, messageID: .init(uuid: UUID())), ordinal: 0)
        let second = V2ResourceReferenceContext.message(.init(roomID: room, messageID: .init(uuid: UUID())), ordinal: 0)
        try await store.indexResource(resource, reference: first, businessRevision: 1)
        try await store.indexResource(resource, reference: second, businessRevision: 1)
        #expect(try await store.resourceDirectory().entries.count == 1)
        #expect(try await store.resourceDirectory().entries.first?.referenceCount == 2)
        try await store.revokeResourceReference(first, businessRevision: 2)
        try await store.indexResource(resource, reference: first, businessRevision: 1)
        #expect(try await store.resourceDirectory().entries.first?.referenceCount == 1)
        try await store.revokeResourceReference(second, businessRevision: 2)
        #expect(try await store.resourceDirectory().entries.isEmpty)
        try await store.close(); try FileManager.default.removeItem(at: directory)
    }

    @Test func revocationBeforeMetadataAndConflictingRevisionAreHandled() async throws {
        let (store, directory) = try store(), room = RoomID(uuid: UUID())
        let resource = try descriptor(room: room)
        let reference = V2ResourceReferenceContext.message(.init(roomID: room, messageID: .init(uuid: UUID())), ordinal: 0)
        try await store.revokeResourceReference(reference, businessRevision: 2)
        try await store.indexResource(resource, reference: reference, businessRevision: 2)
        #expect(try await store.resourceDirectory().entries.isEmpty)
        try await store.indexResource(resource, reference: reference, businessRevision: 3)
        let changed = try descriptor(room: room, media: resource.key.mediaID, name: "conflict.jpg")
        await #expect(throws: V2ResourceStorageError.conflict) { try await store.indexResource(changed, reference: reference, businessRevision: 3) }
        #expect(try await store.resourceDirectory().entries.first?.descriptor == resource)
        try await store.close(); try FileManager.default.removeItem(at: directory)
    }

    @Test func keysetPagingRemainsStableWhenMetadataChanges() async throws {
        let (store, directory) = try store(), room = RoomID(uuid: UUID()), stamp = Date(timeIntervalSince1970: 100)
        var descriptors: [V2ResourceDescriptor] = []
        var references: [V2ResourceReferenceContext] = []
        for index in 0..<7 {
            let resource = try descriptor(room: room, name: "photo_\(index).jpg")
            let reference = V2ResourceReferenceContext.message(.init(roomID: room, messageID: .init(uuid: UUID())), ordinal: 0)
            descriptors.append(resource); references.append(reference)
            try await store.indexResource(resource, reference: reference, businessRevision: 1, now: stamp)
        }
        let first = try await store.resourceDirectory(roomID: room, limit: 3)
        let revised = try descriptor(room: room, media: descriptors[0].key.mediaID, name: "renamed.jpg", revision: 2)
        try await store.indexResource(revised, reference: references[0], businessRevision: 1, now: stamp.addingTimeInterval(100))
        let second = try await store.resourceDirectory(roomID: room, before: first.nextCursor, limit: 3)
        let third = try await store.resourceDirectory(roomID: room, before: second.nextCursor, limit: 3)
        let keys = (first.entries + second.entries + third.entries).map(\.descriptor.key)
        #expect(keys.count == 7 && Set(keys).count == 7)
        #expect(third.nextCursor == nil)
        #expect(try await store.resourceDirectory(search: "%").entries.isEmpty)
        #expect(try await store.resourceDirectory(roomID: .init(uuid: UUID())).entries.isEmpty)
        try await store.close(); try FileManager.default.removeItem(at: directory)
    }

    @Test func avatarIsNotChatFileAndWrongHomeRollsBack() async throws {
        let (store, directory) = try store(), room = RoomID(uuid: UUID())
        let resource = try descriptor(room: room)
        try await store.indexResource(resource, reference: .groupAvatar(room), businessRevision: 1)
        #expect(try await store.resourceDirectory(roomID: room).entries.isEmpty)
        await #expect(throws: V2ResourceStorageError.invalidRecord) {
            try await store.indexResource(resource, reference: .groupAvatar(.init(uuid: UUID())), businessRevision: 2)
        }
        #expect(try await store.resourceDirectory().entries.isEmpty)
        try await store.close(); try FileManager.default.removeItem(at: directory)
    }
}
