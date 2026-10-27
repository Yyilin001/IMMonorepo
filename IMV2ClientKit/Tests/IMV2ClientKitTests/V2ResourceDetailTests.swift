import Foundation
import GRDB
import IMV2Core
import Testing
@testable import IMV2ClientKit

@Suite("Resource management detail and categories", .timeLimit(.minutes(1)))
struct V2ResourceDetailTests {
    @Test func measuredVideoMetadataSurvivesDatabaseReopenAndBothReadModels() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("timed-resource-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let user = UserID(uuid: UUID()), room = RoomID(uuid: UUID())
        let binding = V2LocalInstallationBinding(value: UUID())
        let database = root.appendingPathComponent("resources.sqlite")
        let descriptor = try V2ResourceDescriptor(key: .init(home: .room(room), mediaID: .init(uuid: UUID())), revision: 1,
            displayName: .init("实测视频.mp4"), contentType: "video/mp4", byteCount: 1024,
            checksum: .init(value: String(repeating: "a", count: 64)), state: .ready,
            pixelWidth: 64, pixelHeight: 48, durationMilliseconds: 500)
        let initial = try GRDBV2LocalSyncStore(databaseURL: database, installationBinding: binding, userID: user)
        try await initial.indexResource(descriptor, reference: .message(.init(roomID: room, messageID: .init(uuid: UUID())), ordinal: 0), businessRevision: 1)
        try await initial.close()
        let reopened = try GRDBV2LocalSyncStore(databaseURL: database, installationBinding: binding, userID: user)
        let center = try await V2ResourceCenter.make(scope: .init(incarnation: UUID(), accountID: user, directory: root.appendingPathComponent("account"), cacheDirectory: root.appendingPathComponent("cache")), store: reopened)
        do {
            #expect(try await reopened.resourceDirectory(category: .video).entries.first?.descriptor == descriptor)
            #expect(try await center.details(for: descriptor.key)?.descriptor == descriptor)
            await center.close(); try await reopened.close()
        } catch { await center.close(); try? await reopened.close(); throw error }
    }
    @Test func imageCategoryIncludesAnimatedImagesWithoutIncludingOtherTypes() async throws {
        let f = try await Fixture()
        for type in ["image/png", "image/gif", "video/mp4", "application/pdf"] {
            _ = try await f.add(type: type)
        }
        #expect(try await f.store.resourceDirectory(category: .image).entries.count == 2)
        let stream = try await f.center.snapshots(for: .init(category: .image))
        var iterator = stream.makeAsyncIterator()
        guard case .available(let page) = await iterator.next() else { Issue.record("Missing local category snapshot"); return }
        #expect(Set(page.entries.map(\.descriptor.contentType)) == ["image/png", "image/gif"])
        try await f.remove()
    }

    @Test func detailsPageSourcesAndRevocationBlocksBothMetadataAndOldSource() async throws {
        let f = try await Fixture(), resource = try await f.add()
        for _ in 0..<52 {
            try await f.store.indexResource(resource, reference: .message(.init(roomID: f.room, messageID: .init(uuid: UUID())), ordinal: 0), businessRevision: 1)
        }
        let first = try #require(try await f.center.details(for: resource.key))
        #expect(first.descriptor == resource && first.sources.count == 50)
        let cursor = try #require(first.nextSourceCursor)
        let second = try #require(try await f.center.details(for: resource.key, beforeSources: cursor))
        #expect(second.sources.count == 3 && second.nextSourceCursor == nil)
        #expect(Set(first.sources + second.sources).count == 53)
        #expect(first.variants.first?.localState == .needsDownload)
        let source = try #require(first.sources.first)
        #expect(try await f.center.containsSource(source, for: resource.key))
        try await f.store.revokeResourceReference(.message(source.location, ordinal: source.ordinal), businessRevision: 2)
        #expect(try await f.center.containsSource(source, for: resource.key) == false)
        #expect(try await f.center.details(for: resource.key)?.sources.count == 50)
        try await f.store.databasePool.write { db in
            try db.execute(sql: "INSERT INTO v2_room_membership_states(room_id,membership_revision,source_event_id,is_member) VALUES(?,1,?,0)", arguments: [f.room.rawValue,UUID().uuidString])
        }
        #expect(try await f.center.details(for: resource.key) == nil)
        #expect(try await f.center.containsSource(source, for: resource.key) == false)
        try await f.remove()
    }

    @Test func sourceChecksRejectCancelledCallersAndClosedAccounts() async throws {
        let f = try await Fixture()
        do {
            let resource = try await f.add()
            let source = try #require(try await f.center.details(for: resource.key)?.sources.first)
            #expect(try await f.center.containsSource(source, for: resource.key))
            let cancelled = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await f.center.containsSource(source, for: resource.key)
            }
            await #expect(throws: CancellationError.self) { try await cancelled.value }
            #expect(try await f.center.containsSource(source, for: resource.key))
            try await f.store.revokeResourceReference(.message(source.location, ordinal: source.ordinal), businessRevision: 2)
            #expect(try await f.center.containsSource(source, for: resource.key) == false)
            await f.center.close()
            await #expect(throws: V2ResourceStorageError.closed) { try await f.center.containsSource(source, for: resource.key) }
        } catch { try await f.remove(); throw error }
        try await f.remove()
    }

    @Test func retentionIsVisibleInDetailsButNeverGrantsAccessAfterWithdrawal() async throws {
        let f = try await Fixture(), resource = try await f.add()
        try await f.center.setRetained(true, variant: .init(resource: resource.key))
        let detail = try #require(try await f.center.details(for: resource.key))
        #expect(detail.variants.first?.isRetained == true)
        #expect(detail.variants.first?.localState == .needsDownload)
        let source = try #require(detail.sources.first)
        try await f.store.revokeResourceReference(.message(source.location, ordinal: source.ordinal), businessRevision: 2)
        #expect(try await f.center.details(for: resource.key) == nil)
        await #expect(throws: V2ResourceStorageError.unavailable) {
            try await f.center.setRetained(true, variant: .init(resource: resource.key))
        }
        try await f.remove()
    }

    private struct Fixture {
        let root: URL, store: GRDBV2LocalSyncStore, center: V2ResourceCenter
        let room = RoomID(uuid: UUID())
        init() async throws {
            root = FileManager.default.temporaryDirectory.appending(path: "resource-detail-\(UUID())")
            let user = UserID(uuid: UUID())
            store = try .init(databaseURL: root.appending(path: "V2.sqlite"), installationBinding: .init(value: UUID()), userID: user)
            center = try await .make(scope: .init(incarnation: UUID(), accountID: user, directory: root.appending(path: "account"), cacheDirectory: root.appending(path: "cache")), store: store)
        }
        func add(type: String = "image/png") async throws -> V2ResourceDescriptor {
            let descriptor = try resourceDescriptorFixture(room: room.rawValue, media: UUID().uuidString, contentType: type, bytes: 42)
            try await store.indexResource(descriptor, reference: .message(.init(roomID: room, messageID: .init(uuid: UUID())), ordinal: 0), businessRevision: 1)
            return descriptor
        }
        func remove() async throws { await center.close(); try await store.close(); try FileManager.default.removeItem(at: root) }
    }
}
