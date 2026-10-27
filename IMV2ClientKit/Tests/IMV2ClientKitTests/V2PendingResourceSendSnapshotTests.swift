import Foundation
import IMV2Core
@testable import IMV2ClientKit
import Testing

@Suite("Pending resource send snapshot", .timeLimit(.minutes(1)))
struct V2PendingResourceSendSnapshotTests {
    @Test("mixed preparation, handoff and room scoped snapshots do not duplicate submitted rows")
    func mixedPreparationAndHandoff() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "pending-resource-snapshot-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let room = RoomID(uuid: UUID()), otherRoom = RoomID(uuid: UUID()), user = UserID(uuid: UUID())
        let store = try GRDBV2LocalSyncStore(databaseURL: directory.appending(path: "local.sqlite"),
            installationBinding: .init(value: UUID()), userID: user)
        let uploadID = UUID()
        let upload = try V2ResourceUploadRequest(operationID: .init(uuid: UUID()), mediaID: .init(uuid: UUID()),
            usage: .messageAttachment(room), contentType: "image/png", byteCount: 3,
            checksum: .init(value: String(repeating: "a", count: 64)))
        _ = try await store.prepareMetadataResourceTransfer(id: uploadID, request: upload, localAssetID: .init())
        let uploadLocator = V2ResourceUploadLocator(home: .room(room), sessionID: try .init(uuid: UUID()))
        try await store.saveResourceSession(.init(locator: uploadLocator, mediaID: upload.mediaID, generation: 1,
            state: .completed, resourceState: .ready, expiresAt: Date().addingTimeInterval(300),
            bindableUntil: Date().addingTimeInterval(300)), for: uploadID)

        let importID = UUID()
        let imported = try V2ResourceImportRequest(operationID: .init(uuid: UUID()),
            source: .message(location: .init(roomID: otherRoom, messageID: .init(uuid: UUID())), mediaID: .init(uuid: UUID()), variantID: nil),
            targetUsage: .messageAttachment(room), targetMediaID: .init(uuid: UUID()))
        try await store.prepareResourceImport(id: importID, request: imported)
        let importLocator = V2ResourceImportLocator(home: .room(room), operationID: imported.operationID)
        try await store.seedResourceImportStatus(.init(locator: importLocator, mediaID: imported.targetMediaID, state: .processing, bindableUntil: nil), id: importID)

        let intent = try V2SendIntent(id: UUID(), roomID: room, clientMessageID: .init(uuid: UUID()),
            text: "mixed resources", attachmentJobIDs: [uploadID, importID])
        try await store.freezeMetadataSendIntent(intent)
        let otherIntent = try V2SendIntent(id: UUID(), roomID: otherRoom, clientMessageID: .init(uuid: UUID()),
            text: "other room", attachmentJobIDs: [])
        try await store.freezeMetadataSendIntent(otherIntent)

        let preparing = try await store.pendingResourceSendSnapshot(in: room, page: 0)
        #expect(preparing.preparing.count == 1)
        #expect(preparing.preparing[0].id == intent.id)
        #expect(preparing.preparing[0].completed == 1 && preparing.preparing[0].total == 2)
        #expect(preparing.preparing[0].isProcessing)
        #expect(preparing.submitted.isEmpty)
        #expect(!preparing.hasNext)

        try await store.seedResourceImportStatus(.init(locator: importLocator, mediaID: imported.targetMediaID, state: .ready,
            bindableUntil: Date().addingTimeInterval(300)), id: importID)
        let ready = try await store.pendingResourceSendSnapshot(in: room, page: 0)
        #expect(ready.preparing[0].completed == 2 && ready.preparing[0].total == 2)
        _ = try await store.handOffSendIntent(intent.id)
        _ = try await store.handOffSendIntent(otherIntent.id)

        let submitted = try await store.pendingResourceSendSnapshot(in: room, page: 0)
        #expect(submitted.preparing.isEmpty)
        #expect(submitted.submitted.map(\.id) == [intent.id])
        #expect(submitted.submitted[0].text == "mixed resources")
        let repeated = try await store.pendingResourceSendSnapshot(in: room, page: 0)
        #expect(repeated.submitted == submitted.submitted)
        #expect(repeated.submitted.count == 1)

        let other = try await store.pendingResourceSendSnapshot(in: otherRoom, page: 0)
        #expect(other.preparing.isEmpty)
        #expect(other.submitted.map(\.id) == [otherIntent.id])
        try await store.close()
    }
}
