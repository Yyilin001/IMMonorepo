import Foundation
import IMV2Core
@testable import IMV2ClientKit
import Testing

@Suite("Resource directory page persistence", .timeLimit(.minutes(1)))
struct V2ResourceDirectorySyncTests {
    private func item(room: RoomID, sequence: UInt64 = 9, mediaID: MediaID = .init(uuid: UUID()), name: String = "photo.jpg") throws -> V2RoomResourceItem {
        try .init(messageID: .init(uuid: UUID()), messageRevision: 1,
            position: .init(roomSequence: sequence, ordinal: 0, mediaID: mediaID), createdAt: 1000,
            descriptor: .init(key: .init(home: .room(room), mediaID: mediaID), revision: 1, displayName: .init(name),
                contentType: "image/jpeg", byteCount: 32, checksum: .init(value: String(repeating: "a", count: 64)), state: .ready))
    }

    @Test func centerFetchesAndIndexesPagesAndStopsAtTheEnd() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("resource-sync-\(UUID())")
        let user = UserID(uuid: UUID()), room = RoomID(uuid: UUID()), entry = try item(room: room)
        let store = try GRDBV2LocalSyncStore(databaseURL: directory.appendingPathComponent("V2.sqlite"), installationBinding: .init(value: UUID()), userID: user)
        let center = try await V2ResourceCenter.make(scope: .init(incarnation: UUID(), accountID: user, directory: directory, cacheDirectory: directory.appending(path: "cache-scope")), store: store)
        let first = try V2RoomResourcePage(items: [entry], snapshotUpperRoomSequence: 10, nextCursor: "cursor-fixture")
        let second = try V2RoomResourcePage(items: [], snapshotUpperRoomSequence: 10, nextCursor: nil)
        let reader = PagedResourceReader(pages: [first,second])
        let stream = try await center.snapshots(for: .init(roomID: room))
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next() == .available(.init(entries: [], nextCursor: nil)))
        #expect(try await center.synchronize(roomID: room, query: .init(), using: reader) == first)
        guard case .available(let directoryPage) = await iterator.next() else { Issue.record("Missing directory commit"); return }
        #expect(directoryPage.entries.first?.descriptor == entry.descriptor)
        #expect(try await store.resourceDirectoryScan(roomID: room)?.query.cursor == "cursor-fixture")
        #expect(try await center.synchronize(roomID: room, query: .init(), using: reader, restart: false) == second)
        #expect(try await center.synchronize(roomID: room, query: .init(), using: reader, restart: false) == nil)
        #expect(await reader.calls.map(\.cursor) == [nil,"cursor-fixture"])
        await center.close(); try await store.close(); try FileManager.default.removeItem(at: directory)
    }

    @Test func newerScanRejectsOldResponseAndItsMetadata() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("resource-stale-scan-\(UUID())")
        let store = try GRDBV2LocalSyncStore(databaseURL: directory.appendingPathComponent("V2.sqlite"), installationBinding: .init(value: UUID()), userID: .init(uuid: UUID()))
        let room = RoomID(uuid: UUID())
        let old = try await store.beginResourceDirectoryScan(roomID: room, query: .init())
        let current = try await store.beginResourceDirectoryScan(roomID: room, query: .init())
        let page = try V2RoomResourcePage(items: [item(room: room)], snapshotUpperRoomSequence: 10, nextCursor: nil)
        await #expect(throws: V2ResourceStorageError.conflict) { try await store.applyResourceDirectoryPage(page, to: old) }
        #expect(try await store.resourceDirectory().entries.isEmpty)
        #expect(try await store.resourceDirectoryScan(roomID: room)?.id == current.id)
        try await store.applyResourceDirectoryPage(page, to: current)
        await #expect(throws: V2ResourceStorageError.conflict) { try await store.applyResourceDirectoryPage(page, to: current) }
        #expect(try await store.resourceDirectory().entries.count == 1)
        try await store.close(); try FileManager.default.removeItem(at: directory)
    }

    @Test func unchangedContinuationDoesNotPublishMetadataOrConsumeCheckpoint() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("resource-stalled-page-\(UUID())")
        let store = try GRDBV2LocalSyncStore(databaseURL: directory.appendingPathComponent("V2.sqlite"),
            installationBinding: .init(value: UUID()), userID: .init(uuid: UUID()))
        let room = RoomID(uuid: UUID()), first = try item(room: room, sequence: 9), second = try item(room: room, sequence: 8)
        let start = try await store.beginResourceDirectoryScan(roomID: room, query: .init())
        try await store.applyResourceDirectoryPage(.init(items: [first], snapshotUpperRoomSequence: 10, nextCursor: "same-cursor"), to: start)
        let continuation = try #require(await store.resourceDirectoryScan(roomID: room))
        let stalled = try V2RoomResourcePage(items: [second], snapshotUpperRoomSequence: 10, nextCursor: "same-cursor")
        await #expect(throws: V2ResourceStorageError.invalidRecord) {
            try await store.applyResourceDirectoryPage(stalled, to: continuation)
        }
        #expect(try await store.resourceDirectory().entries.map(\.descriptor.key) == [first.descriptor.key])
        #expect(try await store.resourceDirectoryScan(roomID: room) == continuation)
        // Rejection leaves the original request eligible for a valid retry.
        try await store.applyResourceDirectoryPage(.init(items: [second], snapshotUpperRoomSequence: 10, nextCursor: nil), to: continuation)
        #expect(try await store.resourceDirectory().entries.count == 2)
        #expect(try await store.resourceDirectoryScan(roomID: room)?.query.cursor == nil)
        try await store.close(); try FileManager.default.removeItem(at: directory)
    }

    @Test func invalidMetadataRollsBackEveryBindingAndCheckpoint() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("resource-page-rollback-\(UUID())")
        let store = try GRDBV2LocalSyncStore(databaseURL: directory.appendingPathComponent("V2.sqlite"), installationBinding: .init(value: UUID()), userID: .init(uuid: UUID()))
        let room = RoomID(uuid: UUID()), media = MediaID(uuid: UUID())
        let scan = try await store.beginResourceDirectoryScan(roomID: room, query: .init())
        let first = try item(room: room, sequence: 9, mediaID: media)
        let conflicting = try item(room: room, sequence: 8, mediaID: media, name: "different-name.jpg")
        let page = try V2RoomResourcePage(items: [first,conflicting], snapshotUpperRoomSequence: 10, nextCursor: nil)
        await #expect(throws: V2ResourceStorageError.conflict) { try await store.applyResourceDirectoryPage(page, to: scan) }
        #expect(try await store.resourceDirectory().entries.isEmpty)
        #expect(try await store.resourceDirectoryScan(roomID: room) == scan)
        try await store.close(); try FileManager.default.removeItem(at: directory)
    }
}
private actor PagedResourceReader: V2RoomResourceDirectoryReading {
    var pages: [V2RoomResourcePage]
    var calls: [V2RoomResourceQuery] = []
    init(pages: [V2RoomResourcePage]) { self.pages = pages }
    func query(roomID: RoomID, query: V2RoomResourceQuery) throws -> V2RoomResourcePage {
        calls.append(query)
        guard !pages.isEmpty else { throw V2ClientResourceDirectoryError.unavailable }
        return pages.removeFirst()
    }
}
