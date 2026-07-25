import Foundation
import IMV2Core
@testable import IMV2Server
import Testing

@Suite("V2 snapshot staging contract")
struct V2SyncServiceSnapshotTests {
    @Test("malformed snapshot pages are rejected before the store receives a reset request")
    func rejectsInvalidSnapshotBeforePersistence() async throws {
        let store = RecordingSnapshotStore()
        let service = V2SyncService(store: store, now: { Date(timeIntervalSince1970: 1_750_000_000) })
        let stage = try invalidStage()

        await #expect(throws: V2SnapshotProjectionError.invalidPage) {
            _ = try await service.stageReset(userID: .init("00000000-0000-0000-0000-000000000801"), deviceID: .init("00000000-0000-0000-0000-000000000802"), snapshot: stage)
        }
        #expect(await store.stagedCount() == 0)
    }

    @Test("valid deterministic projection pages reach the durable staging boundary")
    func validSnapshotReachesStore() async throws {
        let store = RecordingSnapshotStore()
        let service = V2SyncService(store: store, now: { Date(timeIntervalSince1970: 1_750_000_000) })
        let page = try V2SnapshotProjectionCodec.encode(.init(
            messages: [],
            relationships: [try .init(targetUserID: .init("00000000-0000-0000-0000-000000000804"), state: .accepted, requestedByUserID: nil, updatedAt: .distantFuture)],
            userBlocks: [.init(targetUserID: try .init("00000000-0000-0000-0000-000000000805"), isBlocked: true, updatedAt: .distantFuture)],
            strangerMessagePreference: .init(allowsStrangerMessages: true, updatedAt: .distantFuture)
        ))
        let stage = try validStage(page: page)

        #expect(try await service.stageReset(userID: .init("00000000-0000-0000-0000-000000000801"), deviceID: .init("00000000-0000-0000-0000-000000000802"), snapshot: stage) == 2)
        #expect(await store.stagedCount() == 1)
    }

    @Test("the server rejects duplicate social state across staged snapshot pages")
    func rejectsDuplicateSocialStateAcrossPages() async throws {
        let store = RecordingSnapshotStore()
        let service = V2SyncService(store: store, now: { Date(timeIntervalSince1970: 1_750_000_000) })
        let target = try UserID("00000000-0000-0000-0000-000000000806")
        let first = try V2SnapshotProjectionCodec.encode(.init(messages: [], relationships: [try .init(targetUserID: target, state: .accepted, requestedByUserID: nil, updatedAt: .distantFuture)]))
        let second = try V2SnapshotProjectionCodec.encode(.init(messages: [], relationships: [try .init(targetUserID: target, state: .accepted, requestedByUserID: nil, updatedAt: .distantFuture)]))
        let stage = try validStage(pages: [first, second])

        await #expect(throws: V2SnapshotProjectionError.invalidPage) {
            _ = try await service.stageReset(userID: .init("00000000-0000-0000-0000-000000000801"), deviceID: .init("00000000-0000-0000-0000-000000000802"), snapshot: stage)
        }
        #expect(await store.stagedCount() == 0)
    }

    @Test("the server rejects a snapshot that assigns one room sequence to a message and moderation action")
    func rejectsConflictingRoomEventPositions() async throws {
        let store = RecordingSnapshotStore()
        let service = V2SyncService(store: store, now: { Date(timeIntervalSince1970: 1_750_000_000) })
        let roomID = try RoomID("00000000-0000-0000-0000-000000000807")
        let message = try V2SnapshotMessageProjection(sourceEventID: .init("00000000-0000-0000-0000-000000000808"), messageID: .init("00000000-0000-0000-0000-000000000809"), roomID: roomID, roomSequence: 3, senderUserID: .init("00000000-0000-0000-0000-000000000810"), text: "message", createdAt: Date(timeIntervalSince1970: 1_750_000_000))
        let action = try V2SnapshotModerationProjection(sourceEventID: .init("00000000-0000-0000-0000-000000000811"), roomID: roomID, roomSequence: 3, actorUserID: .init("00000000-0000-0000-0000-000000000812"), targetUserID: .init("00000000-0000-0000-0000-000000000813"), muteUntil: Date(timeIntervalSince1970: 1_750_000_100), createdAt: Date(timeIntervalSince1970: 1_750_000_001))
        let page = try V2SnapshotProjectionCodec.encode(.init(messages: [message], moderationActions: [action]))

        await #expect(throws: V2SnapshotProjectionError.invalidPage) {
            _ = try await service.stageReset(userID: .init("00000000-0000-0000-0000-000000000801"), deviceID: .init("00000000-0000-0000-0000-000000000802"), snapshot: validStage(page: page))
        }
        #expect(await store.stagedCount() == 0)
    }

    private func invalidStage() throws -> V2SnapshotStage {
        try validStage(page: Data("not-a-snapshot".utf8))
    }

    private func validStage(page: Data) throws -> V2SnapshotStage {
        try validStage(pages: [page])
    }

    private func validStage(pages: [Data]) throws -> V2SnapshotStage {
        try .init(
            snapshotID: .init("00000000-0000-0000-0000-000000000803"),
            baseSequence: 0,
            manifestDigest: "snapshot-manifest",
            nextSyncToken: .init("snapshot-token"),
            receipt: .init("snapshot-receipt"),
            expiresAt: .distantFuture,
            schemaVersion: V2SnapshotProjectionCodec.schemaVersion,
            capabilityProfile: "base",
            pages: pages.enumerated().map { .init(digest: "page-digest-\($0.offset)", payload: $0.element) }
        )
    }
}

private actor RecordingSnapshotStore: V2SyncStore {
    private var staged = 0

    func pull(userID _: UserID, deviceID _: DeviceID, syncToken _: V2SyncToken?, maxRecords _: Int, now _: Date) throws -> V2SyncPullResult { throw V2SyncStoreError.invalidOrExpiredSyncToken }
    func acknowledge(userID _: UserID, deviceID _: DeviceID, generation _: UInt64, highestContiguousSequence _: UInt64, receipt _: V2SyncReceipt, now _: Date) {}
    func stageReset(userID _: UserID, deviceID _: DeviceID, snapshot _: V2SnapshotStage, now _: Date) -> UInt64 { staged += 1; return 2 }
    func fetchSnapshotManifest(userID _: UserID, deviceID _: DeviceID, snapshotID _: SnapshotID, generation _: UInt64, now _: Date) throws -> V2SnapshotManifest { throw V2SyncStoreError.snapshotExpiredOrInvalid }
    func fetchSnapshotPage(userID _: UserID, deviceID _: DeviceID, snapshotID _: SnapshotID, generation _: UInt64, manifestDigest _: String, index _: UInt32, now _: Date) throws -> V2SnapshotPage { throw V2SyncStoreError.snapshotExpiredOrInvalid }
    func acknowledgeSnapshot(userID _: UserID, deviceID _: DeviceID, snapshotID _: SnapshotID, generation _: UInt64, baseSequence _: UInt64, receipt _: V2SyncReceipt, now _: Date) {}
    func stagedCount() -> Int { staged }
}
