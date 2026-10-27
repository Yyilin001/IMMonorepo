import Foundation
import IMV2Core
@testable import IMV2ClientKit
import Testing

@Suite("Accepted upload catalog bindings")
struct V2AcceptedResourceBindingTests {
    @Test(arguments: ["image/jpeg", "audio/wav", "video/mp4"])
    func receiptDoesNotInventMetadataBeforeAuthoritativeProjection(contentType: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("accepted-resource-\(UUID())")
        let store = try GRDBV2LocalSyncStore(databaseURL: directory.appendingPathComponent("V2.sqlite"), installationBinding: .init(value: UUID()), userID: .init(uuid: UUID()))
        let room = RoomID(uuid: UUID()), job = UUID()
        let request = try V2ResourceUploadRequest(operationID: .init(uuid: UUID()), mediaID: .init(uuid: UUID()), usage: .messageAttachment(room),
            contentType: contentType, byteCount: 32, checksum: .init(value: String(repeating: "a", count: 64)), displayName: .init("真实附件.jpg"))
        _ = try await store.prepareMetadataResourceTransfer(id: job, request: request, localAssetID: .init(job))
        let now = Date()
        try await store.saveResourceSession(.init(locator: .init(home: .room(room), sessionID: .init(uuid: UUID())), mediaID: request.mediaID,
            generation: 1, state: .completed, resourceState: .ready, expiresAt: now.addingTimeInterval(600), bindableUntil: now.addingTimeInterval(600)), for: job)
        let intent = try V2SendIntent(id: UUID(), roomID: room, clientMessageID: .init(uuid: UUID()), text: "photo", attachmentJobIDs: [job])
        try await store.freezeMetadataSendIntent(intent)
        _ = try await store.handOffSendIntent(intent.id)
        #expect(try await store.resourceDirectory().entries.isEmpty)
        let accepted = try V2MessageOperationAcceptance(messageID: .init(uuid: UUID()), roomSequence: 9)
        try await store.completeResourceSendFixture(intent.clientMessageID, result: .accepted(accepted), now: now)
        #expect(try await store.resourceDirectory(roomID: room).entries.isEmpty)
        let descriptor = try V2ResourceDescriptor(key: .init(home: .room(room), mediaID: request.mediaID),
            revision: 1, displayName: request.displayName, contentType: contentType,
            byteCount: request.byteCount, checksum: request.checksum, state: .ready,
            pixelWidth: contentType == "audio/wav" ? nil : 64,
            pixelHeight: contentType == "audio/wav" ? nil : 48,
            durationMilliseconds: contentType == "image/jpeg" ? nil : 2000)
        try await store.indexResource(descriptor,
            reference: .message(.init(roomID: room, messageID: accepted.messageID), ordinal: 0), businessRevision: 1)
        let page = try await store.resourceDirectory(roomID: room)
        #expect(page.entries.first?.descriptor == descriptor)
        #expect(page.entries.count == 1)
        #expect(page.entries.first?.descriptor.displayName.value == "真实附件.jpg")
        #expect(page.entries.first?.descriptor.checksum == request.checksum)
        let journal = await store.resourceFileJournal()
        let key = V2ResourceVariantKey(resource: .init(home: .room(room), mediaID: request.mediaID))
        #expect(try journal.variant(key)?.fileID == journal.localAsset(.init(job))?.fileID)
        #expect(try journal.variant(key)?.descriptor.checksum == request.checksum)
        try await store.completeResourceSendFixture(intent.clientMessageID, result: .accepted(accepted), now: now)
        #expect(try await store.resourceDirectory(roomID: room).entries.first?.referenceCount == 1)
        try await store.revokeResourceReference(.message(.init(roomID: room, messageID: accepted.messageID), ordinal: 0), businessRevision: 2)
        try await store.completeResourceSendFixture(intent.clientMessageID, result: .accepted(accepted), now: now)
        #expect(try await store.resourceDirectory(roomID: room).entries.isEmpty)
        try await store.close(); try FileManager.default.removeItem(at: directory)
    }
}
