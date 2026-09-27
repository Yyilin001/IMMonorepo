import Foundation
@testable import IMV2ClientKit
import IMV2Core
import Testing
@testable import IMApp

@MainActor
struct V2AttachmentStagingLifecycleTests {
    @Test("account closure preserves unknown group-avatar sources and re-entry cleans only unreferenced drafts")
    func preserveDurableSources() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "im-staging-durable-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appending(path: "staging"), source = root.appending(path: "source.png")
        try Data([1, 2, 3]).write(to: source)
        let stager = try V2FileConversationAttachmentStager(directory: directory)
        let kept = try await stager.stageImportedFile(at: source), orphan = try await stager.stageImportedFile(at: source)
        let actor = UserID(uuid: UUID()), room = RoomID(uuid: UUID()), binding = V2LocalInstallationBinding(value: UUID())
        let database = root.appending(path: "db.sqlite")
        let store = try GRDBV2LocalSyncStore(databaseURL: database, installationBinding: binding, userID: actor)
        let request = try V2ResourceUploadRequest(operationID: .init(uuid: UUID()), mediaID: .init(uuid: UUID()), usage: .groupAvatar(room),
            contentType: "image/png", byteCount: kept.byteCount,
            checksum: .init(value: V2ResourceFileDigest.sha256(fileURL: kept.fileURL, expectedByteCount: kept.byteCount)))
        _ = try await store.prepareResourceTransfer(id: kept.id, request: request, localFileToken: kept.fileURL.lastPathComponent)
        let command = try V2GroupAvatarCommand(operationID: .init(uuid: UUID()), roomID: room, expectedRevision: 0, mutation: .set(request.mediaID))
        _ = try await store.freezeGroupAvatarIntent(actorUserID: actor, command: command, uploadJobID: kept.id)
        try await store.requestGroupAvatarRecovery(command.operationID, action: .query)
        try await stager.close(preservingDurableFiles: true)
        try await store.close()
        await #expect(throws: CancellationError.self) { _ = try await stager.stageImportedFile(at: source) }
        #expect(try Data(contentsOf: kept.fileURL) == Data([1, 2, 3]))
        let reopened = try GRDBV2LocalSyncStore(databaseURL: database, installationBinding: binding, userID: actor)
        let resumedStager = try V2FileConversationAttachmentStager(directory: directory)
        let retained = try await reopened.retainedResourceFileTokens()
        await resumedStager.discardOrphanedStagedFiles(retaining: retained, olderThan: .distantFuture)
        #expect(FileManager.default.fileExists(atPath: kept.fileURL.path))
        #expect(!FileManager.default.fileExists(atPath: orphan.fileURL.path))
        #expect(try await reopened.groupAvatarIntent(command.operationID)?.recoveryAction == .query)
        try await resumedStager.close(preservingDurableFiles: true); try await reopened.close()
    }

    @Test("cancellation after import admission removes the incomplete copy")
    func cancelAtCopyBoundary() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "im-staging-copy-cancel-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "source.bin")
        try Data(repeating: 7, count: 128 * 1_024).write(to: source)
        let directory = root.appending(path: "staging")
        let stager = try V2FileConversationAttachmentStager(directory: directory, makeUUID: {
            // The existing ID factory runs after admission and before the
            // bounded copy, allowing a deterministic cancellation boundary.
            withUnsafeCurrentTask { $0?.cancel() }
            return UUID()
        })
        let request = Task { try await stager.stageImportedFile(at: source) }
        await #expect(throws: CancellationError.self) { try await request.value }
        #expect(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).isEmpty)
        #expect(try Data(contentsOf: source).count == 128 * 1_024)
        try await stager.close()
    }

    @Test("closed account staging deletes copies and rejects later imports")
    func closeStaging() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "im-staging-close-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "source.txt")
        try Data("external source".utf8).write(to: source)
        let firstDirectory = root.appending(path: "first/staging")
        let first = try V2FileConversationAttachmentStager(directory: firstDirectory)
        let second = try V2FileConversationAttachmentStager(directory: root.appending(path: "second/staging"))
        let copy = try await first.stageImportedFile(at: source)
        let other = try await second.stageImportedFile(at: source)
        #expect(try Data(contentsOf: copy.fileURL) == Data(contentsOf: source))
        try await first.close()
        #expect(!FileManager.default.fileExists(atPath: firstDirectory.path))
        #expect(try Data(contentsOf: other.fileURL) == Data(contentsOf: source))
        await #expect(throws: CancellationError.self) { try await first.stageImportedFile(at: source) }
        try await first.close()
        #expect(!FileManager.default.fileExists(atPath: firstDirectory.path))
        try await second.close()
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test("a cancelled importer never creates a staged copy and normal retry succeeds")
    func cancelledImport() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "im-staging-cancel-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "source.txt")
        try Data("payload".utf8).write(to: source)
        let directory = root.appending(path: "staging")
        let stager = try V2FileConversationAttachmentStager(directory: directory)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await stager.stageImportedFile(at: source)
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).isEmpty)
        let retry = try await stager.stageImportedFile(at: source)
        #expect(try Data(contentsOf: retry.fileURL) == Data(contentsOf: source))
        try await stager.close()
    }
}
