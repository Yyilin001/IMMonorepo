import Foundation
import GRDB
import IMV2Core
import Testing
@testable import IMV2ClientKit

struct V2ResourceImagePresentationTests {
    @Test(arguments: [(0, 1), (1, 0), (-1, 1), (16385, 1), (10000, 10000)])
    func dimensionsRejectInvalidAndUnboundedPixels(value: (Int, Int)) {
        #expect(throws: V2ResourceValidationError.invalidUploadRequest) {
            try V2LocalResourceImageDimensions(width: value.0, height: value.1)
        }
    }

    @Test func processingPollIsResponsiveBoundedAndRespectsServerCooldown() {
        #expect(V2NetworkWorkPolicy.resourceProcessingPollDelay(attempt: 0) == 0.5)
        #expect(V2NetworkWorkPolicy.resourceProcessingPollDelay(attempt: 3) == 0.5)
        #expect(V2NetworkWorkPolicy.resourceProcessingPollDelay(attempt: 100) == 30)
        #expect(V2NetworkWorkPolicy.resourceProcessingPollDelay(attempt: -1) == 0.5)
        #expect(V2NetworkWorkPolicy.resourceProcessingPollDelay(attempt: 0, serverDelay: 8) == 8)
        #expect(V2NetworkWorkPolicy.acceptedResultPollDelay(attempt: 0) == 2)
    }

    @Test func unsupportedResourceSchemaPreservesSelectionsOnRejectedReopen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("local.sqlite")
        let binding = V2LocalInstallationBinding(value: UUID()), user = UserID(uuid: UUID())
        let store = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding, userID: user)
        let files = try V2ResourceFileStore(root: root.appendingPathComponent("files"), journal: await store.resourceFileJournal(),
                                           policy: .testBounded(1_048_576))
        let asset = try await files.importOriginal(data: Data([1, 2, 3]), id: .init(), displayName: .init("existing.jpg"),
            contentType: .init("image/jpeg"), purpose: .personalAvatar, maximumBytes: 1024, maximumSelections: 4)
        await files.close(); try await store.close()
        let changed = try DatabaseQueue(path: url.path)
        try await changed.write { db in
            try db.execute(sql: "ALTER TABLE v2_resource_local_assets ADD COLUMN unsupported_field INTEGER")
        }
        try changed.close()
        #expect(throws: V2ClientLocalStorageError.unsupportedResourceSchema) {
            _ = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding, userID: user)
        }
        let inspection = try DatabaseQueue(path: url.path)
        defer { try? inspection.close() }
        let retained = try await inspection.read { db in
            (try String.fetchOne(db, sql: "SELECT checksum FROM v2_resource_local_assets"),
             try Int.fetchOne(db, sql: "SELECT selection_active FROM v2_resource_local_assets"))
        }
        #expect(retained.0 == asset.checksum.value && retained.1 == 1)
    }

    @Test func dimensionsSurviveReopenAndFrozenSendSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let binding = V2LocalInstallationBinding(value: UUID()), user = UserID(uuid: UUID()), room = RoomID(uuid: UUID())
        let url = root.appendingPathComponent("local.sqlite")
        let store = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding, userID: user)
        let journal = await store.resourceFileJournal()
        let files = try V2ResourceFileStore(root: root.appendingPathComponent("files"), journal: journal,
                                           policy: .testBounded(1_048_576))
        let dimensions = try V2LocalResourceImageDimensions(width: 1536, height: 2048)
        let asset = try await files.importOriginal(data: Data([1, 2, 3]), id: .init(), displayName: .init("photo.jpg"),
            contentType: .init("image/jpeg"), purpose: .messageDraft(room), imageDimensions: dimensions,
            maximumBytes: 1024, maximumSelections: 4)
        let malformedDimensions: [(Int?, Int?)] = [(nil, 1), (1, nil), (0, 1), (1, 0), (16_385, 1), (10_000, 10_000)]
        try await store.databasePool.write { db in
            for (width, height) in malformedDimensions {
                #expect(throws: DatabaseError.self) {
                    try db.execute(sql: "UPDATE v2_resource_local_assets SET pixel_width=?,pixel_height=?",
                        arguments: [width, height])
                }
            }
        }
        let job = UUID()
        let request = try V2ResourceUploadRequest(operationID: .init(uuid: job), mediaID: .init(uuid: job),
            usage: .messageAttachment(room), contentType: asset.contentType.value, byteCount: asset.byteCount,
            checksum: asset.checksum, displayName: asset.displayName, clientImageDimensions: dimensions)
        let intent = try V2SendIntent(id: UUID(), roomID: room, clientMessageID: .init(uuid: UUID()), text: "",
                                      attachmentJobIDs: [job])
        try await store.freezeSendIntent(intent, resources: [.init(id: job, request: request, localAssetID: asset.id)])
        let pending = try await store.pendingResourceSendSnapshot(in: room, page: 0)
        #expect(pending.localImages[intent.id]?.map(\.dimensions) == [dimensions])
        #expect(pending.localImages[intent.id]?.map(\.jobID) == [job])
        await files.close(); try await store.close()
        let reopened = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding, userID: user)
        let restored = try await reopened.resourceFileJournal().localAsset(asset.id)
        #expect(restored?.imageDimensions == dimensions)
        #expect(try await reopened.resourceTransfer(id: job)?.request.clientImageDimensions == dimensions)
        #expect(try await reopened.pendingResourceSendSnapshot(in: room, page: 0).localImages[intent.id]?.first?.dimensions == dimensions)
        let replacementID = try await reopened.retryPreparedSendIntent(intent.id, now: .now.addingTimeInterval(2 * 86400))
        #expect(replacementID != intent.id)
        let replacement = try #require(try await reopened.preparingSendIntent(id: replacementID))
        let replacementJob = try #require(replacement.attachmentJobIDs.first)
        #expect(try await reopened.resourceTransfer(id: replacementJob)?.request.clientImageDimensions == dimensions)
        try await reopened.close()
    }
}
