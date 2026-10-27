import Foundation
import IMV2Core
import Testing
@testable import IMV2ClientKit
@testable import IMApp

@MainActor
struct V2AttachmentStagingLifecycleTests {
    @Test("normalized bytes obey the same selection limits and reject cancelled or closed callers")
    func normalizedPhotoAdmissionAndClose() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "photo-original-admission-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await V2OriginalResourceTestFixture(root: root, policy: .init(maximumFileBytes: 8, maximumFileCount: 1))
        await #expect(throws: V2ConversationAttachmentStagingError.invalidByteCount) {
            try await fixture.stager.stageNormalizedPhoto(.init(data: Data(), format: .jpeg), purpose: .personalAvatar)
        }
        await #expect(throws: V2ConversationAttachmentStagingError.fileTooLarge) {
            try await fixture.stager.stageNormalizedPhoto(.init(data: Data(repeating: 1, count: 9), format: .jpeg), purpose: .personalAvatar)
        }
        let photo = V2NormalizedPhoto(data: Data([1,2,3]), format: .png)
        let draft = try await fixture.stager.stageNormalizedPhoto(photo, purpose: .personalAvatar)
        await #expect(throws: V2ConversationAttachmentStagingError.stagingQuotaExceeded) {
            try await fixture.stager.stageNormalizedPhoto(.init(data: Data([4,5,6]), format: .png), purpose: .personalAvatar)
        }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await fixture.stager.stageNormalizedPhoto(photo, purpose: .personalAvatar)
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(try await fixture.read(.selection(draft.localAssetID)) == photo.data)
        #expect(try await fixture.resources.selectedLocalAssets(purpose: .personalAvatar).count == 1)
        #expect(try await fixture.resources.storageSnapshot().files.count == 1)
        try await fixture.close()
        await #expect(throws: CancellationError.self) {
            try await fixture.stager.stageNormalizedPhoto(photo, purpose: .personalAvatar)
        }
        let restored = try await V2OriginalResourceTestFixture(root: root, scope: fixture.scope)
        #expect(try await restored.read(.selection(draft.localAssetID)) == photo.data)
        try await restored.close()
    }

    @Test("cancellation inside the normalized-byte publisher leaves no protected draft or temporary copy")
    func normalizedPhotoCancellationAtCopyBoundary() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "photo-original-copy-cancel-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await V2OriginalResourceTestFixture(root: root, protection: CancellingOriginalProtection())
        let photo = V2NormalizedPhoto(data: Data(repeating: 9, count: 128 * 1024), format: .jpeg)
        await #expect(throws: CancellationError.self) {
            try await fixture.stager.stageNormalizedPhoto(photo, purpose: .personalAvatar)
        }
        #expect(try await fixture.resources.selectedLocalAssets(purpose: .personalAvatar).isEmpty)
        let usage = try await fixture.resources.storageSnapshot()
        #expect(usage.files.isEmpty && usage.transferReservedBytes == 0)
        try await fixture.close()
    }

    @Test("cold reconstruction restores drafts and preserves the independent frozen upload")
    func coldRecoveryPreservesFrozenSources() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "original-recovery-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "source.png"); try Data([1,2,3]).write(to: source)
        let fixture = try await V2OriginalResourceTestFixture(root: root)
        let room = RoomID(uuid: UUID()), draftRoom = RoomID(uuid: UUID())
        let kept = try await fixture.stager.stageImportedFile(at: source, purpose: .groupAvatar(room))
        let draft = try await fixture.stager.stageImportedFile(at: source, purpose: .messageDraft(draftRoom))
        let asset = try #require(try await fixture.resources.localAsset(kept.localAssetID))
        let request = try V2ResourceUploadRequest(operationID: .init(uuid: kept.id), mediaID: .init(uuid: kept.id), usage: .groupAvatar(room),
            contentType: asset.contentType.value, byteCount: asset.byteCount, checksum: asset.checksum, displayName: asset.displayName)
        let command = try V2GroupAvatarCommand(operationID: .init(uuid: UUID()), roomID: room, expectedRevision: 0, mutation: .set(request.mediaID))
        _ = try await fixture.store.freezeGroupAvatarUploadIntent(actorUserID: fixture.scope.accountID, command: command, uploadJobID: kept.id,
            request: request, localAssetID: kept.localAssetID)
        try await fixture.store.requestGroupAvatarRecovery(command.operationID, action: .query)
        try await fixture.close()
        await #expect(throws: CancellationError.self) { try await fixture.stager.stageImportedFile(at: source, purpose: .personalAvatar) }
        let restored = try await V2OriginalResourceTestFixture(root: root, scope: fixture.scope)
        #expect(try await restored.stager.selectedAttachments(purpose: .messageDraft(draftRoom)).map(\.id) == [draft.id])
        #expect(try await restored.stager.selectedAttachments(purpose: .groupAvatar(room)).isEmpty)
        #expect(try await restored.read(.upload(kept.id)) == Data([1,2,3]))
        await restored.stager.discard(draft)
        #expect(try await restored.resources.planCleanup().fileIDs.isEmpty)
        #expect(try await restored.store.groupAvatarIntent(command.operationID)?.recoveryAction == .query)
        #expect(try Data(contentsOf: source) == Data([1,2,3]))
        try await restored.close()
    }

    @Test("cancellation reaches the actual protected publisher without losing the caller's source")
    func cancelAtCopyBoundary() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "original-copy-cancel-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "source.bin"); try Data(repeating: 7, count: 128 * 1024).write(to: source)
        let fixture = try await V2OriginalResourceTestFixture(root: root, protection: CancellingOriginalProtection())
        await #expect(throws: CancellationError.self) { try await fixture.stager.stageImportedFile(at: source, purpose: .personalAvatar) }
        #expect(try await fixture.resources.selectedLocalAssets(purpose: .personalAvatar).isEmpty)
        #expect(try await fixture.resources.storageSnapshot().files.isEmpty)
        #expect(try Data(contentsOf: source).count == 128 * 1024)
        try await fixture.close()
    }

    @Test("normal account close preserves originals and rejects late imports without crossing accounts")
    func closeStaging() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "original-close-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "source.txt"); try Data("external source".utf8).write(to: source)
        let first = try await V2OriginalResourceTestFixture(root: root.appending(path: "first"))
        let second = try await V2OriginalResourceTestFixture(root: root.appending(path: "second"))
        let copy = try await first.stager.stageImportedFile(at: source, purpose: .personalAvatar)
        let other = try await second.stager.stageImportedFile(at: source, purpose: .personalAvatar)
        #expect(try await first.read(.selection(copy.localAssetID)) == Data(contentsOf: source))
        try await first.close()
        #expect(try await second.read(.selection(other.localAssetID)) == Data(contentsOf: source))
        await #expect(throws: CancellationError.self) { try await first.stager.stageImportedFile(at: source, purpose: .personalAvatar) }
        let restored = try await V2OriginalResourceTestFixture(root: first.scope.directory, scope: first.scope)
        #expect(try await restored.read(.selection(copy.localAssetID)) == Data(contentsOf: source))
        try await restored.close(); try await second.close()
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test("an already-cancelled importer creates no draft and retry publishes a borrowable original")
    func cancelledImport() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "original-cancel-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "source.txt"); try Data("payload".utf8).write(to: source)
        let fixture = try await V2OriginalResourceTestFixture(root: root)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await fixture.stager.stageImportedFile(at: source, purpose: .personalAvatar)
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(try await fixture.resources.selectedLocalAssets(purpose: .personalAvatar).isEmpty)
        let retry = try await fixture.stager.stageImportedFile(at: source, purpose: .personalAvatar)
        #expect(try await fixture.read(.selection(retry.localAssetID)) == Data(contentsOf: source))
        try await fixture.close()
    }
}

private struct CancellingOriginalProtection: V2ResourceFileProtectionWriting {
    func apply(_ protection: V2ResourceFileProtection, to file: URL) throws {
        if file.deletingLastPathComponent().lastPathComponent == "partials" { withUnsafeCurrentTask { $0?.cancel() } }
        try V2SystemResourceFileProtectionWriter().apply(protection, to: file)
    }
}
