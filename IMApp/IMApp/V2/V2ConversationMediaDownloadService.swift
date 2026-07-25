import CryptoKit
import Foundation
import IMV2ClientKit
import IMV2Core

/// A local, shareable media file. It intentionally contains no provider URL,
/// credential, or server-side filename; those remain inside ClientKit's
/// one-shot authorization and transfer boundary.
struct V2DownloadedConversationMedia: Hashable, Identifiable, Sendable {
    let mediaID: MediaID
    let fileURL: URL

    var id: MediaID { mediaID }
}

protocol V2ConversationMediaDownloading: Sendable {
    /// Re-authorizes and replaces the local cache entry before returning a
    /// shareable local file. It must not return a provider target.
    func download(_ media: V2MediaReference) async throws -> V2DownloadedConversationMedia
}

enum V2DeviceLocalStorageError: Error, Equatable, Sendable {
    case fileSystemFailure
    case backupExclusionNotApplied
}

/// Applies V2's device-local storage policy to the directory that contains
/// local sync state or downloaded media. The application currently offers no
/// persistent background media transfer, so `Complete` protection is correct
/// for this foreground-only media cache.
enum V2DeviceLocalStoragePolicy {
    static func prepareManagedDirectory(
        _ directory: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        var managedDirectory = directory.standardizedFileURL
        do {
            try fileManager.createDirectory(at: managedDirectory, withIntermediateDirectories: true)
            try applyBackupExclusion(to: &managedDirectory)
            try fileManager.setAttributes(
                [.protectionKey: FileProtectionType.complete],
                ofItemAtPath: managedDirectory.path
            )
        } catch let error as V2DeviceLocalStorageError {
            throw error
        } catch {
            throw V2DeviceLocalStorageError.fileSystemFailure
        }
        return managedDirectory
    }

    static func applyToManagedFile(
        _ fileURL: URL,
        fileManager: FileManager = .default
    ) throws {
        var managedFile = fileURL.standardizedFileURL
        do {
            try applyBackupExclusion(to: &managedFile)
            try fileManager.setAttributes(
                [.protectionKey: FileProtectionType.complete],
                ofItemAtPath: managedFile.path
            )
        } catch let error as V2DeviceLocalStorageError {
            throw error
        } catch {
            throw V2DeviceLocalStorageError.fileSystemFailure
        }
    }

    private static func applyBackupExclusion(to url: inout URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        guard try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true else {
            throw V2DeviceLocalStorageError.backupExclusionNotApplied
        }
    }
}

/// App-facing foreground download coordinator. A fresh ClientKit download is
/// performed for every user request, so the edge rechecks current device,
/// room-membership, withdrawal, and delivered-projection authorization before
/// a cached file is replaced. The cache filename is a one-way digest of the
/// opaque media ID and never exposes an identifier or provider URL on disk.
actor V2ForegroundConversationMediaDownloader: V2ConversationMediaDownloading {
    private let downloader: V2ClientMediaDownloadService
    private let directory: URL
    private let fileManager: FileManager
    private let makeUUID: @Sendable () -> UUID

    init(
        downloader: V2ClientMediaDownloadService,
        directory: URL,
        fileManager: FileManager = .default,
        makeUUID: @escaping @Sendable () -> UUID = UUID.init
    ) throws {
        self.downloader = downloader
        self.directory = try V2DeviceLocalStoragePolicy.prepareManagedDirectory(directory, fileManager: fileManager)
        self.fileManager = fileManager
        self.makeUUID = makeUUID
    }

    func download(_ media: V2MediaReference) async throws -> V2DownloadedConversationMedia {
        try Task.checkCancellation()
        let destination = cacheURL(for: media.mediaID)
        let temporary = directory
            .appendingPathComponent("." + makeUUID().uuidString + ".partial", isDirectory: false)
        defer { try? fileManager.removeItem(at: temporary) }

        try await downloader.download(mediaID: media.mediaID, to: temporary)
        try Task.checkCancellation()

        do {
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: temporary, to: destination)
            try V2DeviceLocalStoragePolicy.applyToManagedFile(destination, fileManager: fileManager)
        } catch {
            throw V2DeviceLocalStorageError.fileSystemFailure
        }
        return .init(mediaID: media.mediaID, fileURL: destination)
    }

    /// Interrupted URLSession downloads leave only random `.partial` files;
    /// this never touches complete cache entries, and never traverses outside
    /// the cache directory.
    func discardOrphanedTemporaryFiles() {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) else { return }
        for entry in entries {
            let candidate = entry.standardizedFileURL
            guard candidate.deletingLastPathComponent() == directory,
                  candidate.lastPathComponent.hasPrefix("."),
                  candidate.pathExtension == "partial",
                  (try? candidate.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            else { continue }
            try? fileManager.removeItem(at: candidate)
        }
    }

    private func cacheURL(for mediaID: MediaID) -> URL {
        let digest = SHA256.hash(data: Data(mediaID.rawValue.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return directory.appendingPathComponent(digest + ".media", isDirectory: false)
    }
}
