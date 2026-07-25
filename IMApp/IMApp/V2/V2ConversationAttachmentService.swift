import Foundation
import IMV2ClientKit
import IMV2Core
import UniformTypeIdentifiers

/// Local, non-persisted staging metadata. A message outbox receives only the
/// resulting opaque media reference; neither this file URL nor its display
/// name can cross the App/ClientKit boundary.
struct V2StagedConversationAttachment: Hashable, Identifiable, Sendable {
    let id: UUID
    let fileURL: URL
    let displayName: String
    let contentType: String
    let byteCount: Int64
}

protocol V2ConversationAttachmentStaging: Sendable {
    func stageImportedFile(at sourceURL: URL) async throws -> V2StagedConversationAttachment
    func discard(_ attachment: V2StagedConversationAttachment) async
}

protocol V2ConversationAttachmentUploading: Sendable {
    /// Returns only after the edge reports scanner-approved availability.
    func upload(_ attachment: V2StagedConversationAttachment) async throws -> V2MediaReference
}

enum V2ConversationAttachmentStagingError: Error, Equatable, Sendable {
    case notRegularFile
    case invalidByteCount
    case fileSystemFailure
}

/// Owns temporary importer copies in a dedicated App Support directory. The
/// importer URL can be security-scoped and is accessed only during the copy;
/// a sandbox-local file is then supplied to the foreground upload client.
actor V2FileConversationAttachmentStager: V2ConversationAttachmentStaging {
    private let directory: URL
    private let fileManager: FileManager
    private let makeUUID: @Sendable () -> UUID

    init(directory: URL, fileManager: FileManager = .default, makeUUID: @escaping @Sendable () -> UUID = UUID.init) throws {
        self.directory = directory.standardizedFileURL
        self.fileManager = fileManager
        self.makeUUID = makeUUID
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw V2ConversationAttachmentStagingError.fileSystemFailure
        }
    }

    func stageImportedFile(at sourceURL: URL) throws -> V2StagedConversationAttachment {
        let accessGranted = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessGranted { sourceURL.stopAccessingSecurityScopedResource() }
        }
        let values: URLResourceValues
        do {
            values = try sourceURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .nameKey, .contentTypeKey])
        } catch {
            throw V2ConversationAttachmentStagingError.fileSystemFailure
        }
        guard values.isRegularFile == true else { throw V2ConversationAttachmentStagingError.notRegularFile }
        guard let fileSize = values.fileSize, fileSize > 0 else { throw V2ConversationAttachmentStagingError.invalidByteCount }
        let id = makeUUID()
        let destination = directory.appendingPathComponent(id.uuidString, isDirectory: false)
        do {
            try fileManager.copyItem(at: sourceURL, to: destination)
        } catch {
            throw V2ConversationAttachmentStagingError.fileSystemFailure
        }
        let contentType = values.contentType
            ?? UTType(filenameExtension: sourceURL.pathExtension.lowercased())
            ?? .data
        let mimeType = contentType.preferredMIMEType ?? "application/octet-stream"
        return .init(
            id: id,
            fileURL: destination,
            displayName: values.name ?? sourceURL.lastPathComponent,
            contentType: mimeType,
            byteCount: Int64(fileSize)
        )
    }

    func discard(_ attachment: V2StagedConversationAttachment) {
        let candidate = attachment.fileURL.standardizedFileURL
        guard candidate.deletingLastPathComponent() == directory else { return }
        try? fileManager.removeItem(at: candidate)
    }

    /// Staged uploads have no durable retry record by design: only a
    /// scanner-approved opaque reference can enter the message outbox.
    /// Therefore a fresh activation can safely remove files left by a killed
    /// foreground upload, while never traversing outside this directory.
    func discardOrphanedStagedFiles() {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for entry in entries {
            let candidate = entry.standardizedFileURL
            guard candidate.deletingLastPathComponent() == directory,
                  (try? candidate.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            else { continue }
            try? fileManager.removeItem(at: candidate)
        }
    }
}

/// App-facing adapter around ClientKit. It generates fresh opaque IDs for an
/// upload attempt and never exposes the short-lived provider target to UI.
actor V2ForegroundConversationAttachmentUploader: V2ConversationAttachmentUploading {
    private let uploader: V2ClientMediaUploadService
    private let makeUUID: @Sendable () -> UUID

    init(uploader: V2ClientMediaUploadService, makeUUID: @escaping @Sendable () -> UUID = UUID.init) {
        self.uploader = uploader
        self.makeUUID = makeUUID
    }

    func upload(_ attachment: V2StagedConversationAttachment) async throws -> V2MediaReference {
        let operationID = try MediaUploadOperationID(makeUUID().uuidString)
        let mediaID = try MediaID(makeUUID().uuidString)
        try await uploader.upload(
            fileURL: attachment.fileURL,
            operationID: operationID,
            mediaID: mediaID,
            contentType: attachment.contentType,
            byteCount: attachment.byteCount
        )
        return .init(mediaID: mediaID)
    }
}
