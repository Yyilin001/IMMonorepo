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
    case fileTooLarge
    case stagingQuotaExceeded
    case fileSystemFailure
}

struct V2ConversationAttachmentStagingPolicy: Equatable, Sendable {
    let maximumFileBytes: Int64
    let maximumDirectoryBytes: Int64
    let maximumFileCount: Int

    init(maximumFileBytes: Int64, maximumDirectoryBytes: Int64, maximumFileCount: Int) {
        precondition(
            maximumFileBytes > 0
                && maximumDirectoryBytes >= maximumFileBytes
                && maximumFileCount > 0
        )
        self.maximumFileBytes = maximumFileBytes
        self.maximumDirectoryBytes = maximumDirectoryBytes
        self.maximumFileCount = maximumFileCount
    }

    /// This device-local safety bound is deliberately independent of the
    /// provider's authoritative limit. A provider may reject a smaller file,
    /// but no configured provider can make the app stage an unbounded file.
    static let standard = Self(
        maximumFileBytes: 50 * 1_024 * 1_024,
        maximumDirectoryBytes: 512 * 1_024 * 1_024,
        maximumFileCount: 64
    )
}

/// Owns temporary importer copies in a dedicated App Support directory. The
/// importer URL can be security-scoped and is accessed only during the copy;
/// a sandbox-local file is then supplied to the foreground upload client.
actor V2FileConversationAttachmentStager: V2ConversationAttachmentStaging {
    private let directory: URL
    private let fileManager: FileManager
    private let policy: V2ConversationAttachmentStagingPolicy
    private let makeUUID: @Sendable () -> UUID

    init(
        directory: URL,
        fileManager: FileManager = .default,
        policy: V2ConversationAttachmentStagingPolicy = .standard,
        makeUUID: @escaping @Sendable () -> UUID = UUID.init
    ) throws {
        self.directory = try V2DeviceLocalStoragePolicy.prepareManagedDirectory(
            directory,
            fileManager: fileManager
        )
        self.fileManager = fileManager
        self.policy = policy
        self.makeUUID = makeUUID
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
        guard Int64(fileSize) <= policy.maximumFileBytes else {
            throw V2ConversationAttachmentStagingError.fileTooLarge
        }
        let usage = try stagingUsage()
        guard usage.fileCount < policy.maximumFileCount,
              usage.byteCount <= policy.maximumDirectoryBytes - Int64(fileSize)
        else { throw V2ConversationAttachmentStagingError.stagingQuotaExceeded }
        let id = makeUUID()
        let destination = directory.appendingPathComponent(id.uuidString, isDirectory: false)
        var copiedByteCount: Int64 = 0
        do {
            copiedByteCount = try copyWithinLimits(
                sourceURL: sourceURL,
                destination: destination,
                maximumDirectoryAddition: policy.maximumDirectoryBytes - usage.byteCount
            )
            try V2DeviceLocalStoragePolicy.applyToManagedFile(destination, fileManager: fileManager)
        } catch let error as V2ConversationAttachmentStagingError {
            try? fileManager.removeItem(at: destination)
            throw error
        } catch let error as V2DeviceLocalStorageError {
            try? fileManager.removeItem(at: destination)
            throw error
        } catch {
            try? fileManager.removeItem(at: destination)
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
            byteCount: copiedByteCount
        )
    }

    private func copyWithinLimits(
        sourceURL: URL,
        destination: URL,
        maximumDirectoryAddition: Int64
    ) throws -> Int64 {
        guard !fileManager.fileExists(atPath: destination.path),
              fileManager.createFile(atPath: destination.path, contents: nil)
        else { throw V2ConversationAttachmentStagingError.fileSystemFailure }
        let source: FileHandle
        do {
            source = try FileHandle(forReadingFrom: sourceURL)
        } catch {
            throw V2ConversationAttachmentStagingError.fileSystemFailure
        }
        defer { try? source.close() }
        let target: FileHandle
        do {
            target = try FileHandle(forWritingTo: destination)
        } catch {
            throw V2ConversationAttachmentStagingError.fileSystemFailure
        }
        defer {
            try? target.close()
        }
        var total: Int64 = 0
        do {
            while let bytes = try source.read(upToCount: 64 * 1_024), !bytes.isEmpty {
                let count = Int64(bytes.count)
                guard total <= policy.maximumFileBytes - count else {
                    throw V2ConversationAttachmentStagingError.fileTooLarge
                }
                guard total <= maximumDirectoryAddition - count else {
                    throw V2ConversationAttachmentStagingError.stagingQuotaExceeded
                }
                try target.write(contentsOf: bytes)
                total += count
            }
            try target.synchronize()
        } catch let error as V2ConversationAttachmentStagingError {
            throw error
        } catch {
            throw V2ConversationAttachmentStagingError.fileSystemFailure
        }
        guard total > 0 else { throw V2ConversationAttachmentStagingError.invalidByteCount }
        return total
    }

    private func stagingUsage() throws -> (fileCount: Int, byteCount: Int64) {
        let entries: [URL]
        do {
            entries = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: []
            )
        } catch {
            throw V2ConversationAttachmentStagingError.fileSystemFailure
        }
        var byteCount: Int64 = 0
        for entry in entries {
            let values: URLResourceValues
            do {
                values = try entry.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            } catch {
                throw V2ConversationAttachmentStagingError.fileSystemFailure
            }
            guard values.isRegularFile == true, let fileSize = values.fileSize, fileSize >= 0 else {
                throw V2ConversationAttachmentStagingError.fileSystemFailure
            }
            let size = Int64(fileSize)
            guard byteCount <= Int64.max - size else {
                throw V2ConversationAttachmentStagingError.stagingQuotaExceeded
            }
            byteCount += size
        }
        return (entries.count, byteCount)
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
