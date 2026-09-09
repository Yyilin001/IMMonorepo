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
    func download(_ media: V2MediaReference, message: V2MediaMessageLocation?) async throws -> V2DownloadedConversationMedia
}

/// Optional local-cache capability. Kept separate from download so existing
/// test/remote implementations do not acquire file-system authority.
protocol V2ConversationMediaCacheDiscarding: Sendable {
    func discard(_ media: V2MediaReference) async
}

enum V2DeviceLocalStorageError: Error, Equatable, Sendable {
    case fileSystemFailure
    case backupExclusionNotApplied
}

struct V2ConversationMediaCachePolicy: Equatable, Sendable {
    let maximumByteCount: Int64
    let maximumEntryCount: Int
    let maximumAge: TimeInterval

    init(
        maximumByteCount: Int64 = 512 * 1_024 * 1_024,
        maximumEntryCount: Int = 256,
        maximumAge: TimeInterval = 7 * 24 * 60 * 60
    ) {
        precondition(maximumByteCount > 0 && maximumEntryCount > 0)
        precondition(maximumAge.isFinite && maximumAge > 0)
        self.maximumByteCount = maximumByteCount
        self.maximumEntryCount = maximumEntryCount
        self.maximumAge = maximumAge
    }
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

/// 账号范围的前台媒体下载器，拥有传输任务和受管缓存目录。
///
/// 每次请求重新获取服务端授权，先写随机 partial，再发布为 opaque 缓存路径。
/// 关闭后拒绝新请求；迟到传输不能重新发布已经结束账号的文件。
actor V2ForegroundConversationMediaDownloader: V2ConversationMediaDownloading, V2ConversationMediaCacheDiscarding {
    private var isClosed = false
    private var transfers: [UUID: Task<V2DownloadedConversationMedia, Error>] = [:]
    private let downloader: V2ClientMediaDownloadService
    private let directory: URL
    private let fileManager: FileManager
    private let cachePolicy: V2ConversationMediaCachePolicy
    private let makeUUID: @Sendable () -> UUID
    private let now: @Sendable () -> Date

    init(
        downloader: V2ClientMediaDownloadService,
        directory: URL,
        fileManager: FileManager = .default,
        cachePolicy: V2ConversationMediaCachePolicy = .init(),
        makeUUID: @escaping @Sendable () -> UUID = UUID.init,
        now: @escaping @Sendable () -> Date = Date.init
    ) throws {
        self.downloader = downloader
        self.directory = try V2DeviceLocalStoragePolicy.prepareManagedDirectory(directory, fileManager: fileManager)
        self.fileManager = fileManager
        self.cachePolicy = cachePolicy
        self.makeUUID = makeUUID
        self.now = now
    }

    /// 重新授权并下载媒体，成功后返回本地可分享路径。
    ///
    /// - Parameters:
    ///   - media: 不透明媒体引用。
    ///   - message: 需要消息可见性授权时使用的位置；其他用途可为 nil。
    /// - Returns: 当前媒体 ID 与完成发布的受管文件 URL。
    /// - Throws: 取消、账号下载器关闭、授权／传输或文件系统错误。
    ///   失败时尝试删除本次 partial，调用者不能将返回前的临时路径用于展示。
    func download(_ media: V2MediaReference, message: V2MediaMessageLocation? = nil) async throws -> V2DownloadedConversationMedia {
        try Task.checkCancellation()
        guard !isClosed else { throw CancellationError() }
        let id = UUID()
        // The account owns and drains the transfer; caller cancellation is
        // explicitly forwarded to this shared lifetime boundary.
        let task = Task { try await self.performDownload(media, message: message) }
        transfers[id] = task
        defer { transfers.removeValue(forKey: id) }
        return try await withTaskCancellationHandler {
            let result = try await task.value
            try Task.checkCancellation()
            guard !isClosed else { throw CancellationError() }
            return result
        } onCancel: { task.cancel() }
    }

    /// 终止下载器并在所有传输结束后删除账号下载目录。
    ///
    /// 取消不能保证底层立刻停止写文件，因此先等待任务，再执行目录清理。
    ///
    /// - Throws: 目录删除失败时返回文件系统错误；可再次调用以重试清理。
    func close() async throws {
        isClosed = true
        let pending = Array(transfers.values)
        for task in pending { task.cancel() }
        for task in pending { _ = await task.result }
        if fileManager.fileExists(atPath: directory.path) {
            do { try fileManager.removeItem(at: directory) }
            catch { throw V2DeviceLocalStorageError.fileSystemFailure }
        }
    }

    private func performDownload(_ media: V2MediaReference, message: V2MediaMessageLocation?) async throws -> V2DownloadedConversationMedia {
        try Task.checkCancellation()
        guard !isClosed else { throw CancellationError() }
        let destination = cacheURL(for: media.mediaID)
        let temporary = directory
            .appendingPathComponent("." + makeUUID().uuidString + ".partial", isDirectory: false)
        defer { try? fileManager.removeItem(at: temporary) }

        try await downloader.download(mediaID: media.mediaID, message: message, to: temporary)
        try Task.checkCancellation()
        guard !isClosed else { throw CancellationError() }

        do {
            // Apply the complete protection policy before the commit. Once
            // the staging file becomes visible at the stable cache URL there
            // is no later fallible step that can report failure while leaving
            // a partially configured cache entry behind.
            try V2DeviceLocalStoragePolicy.applyToManagedFile(temporary, fileManager: fileManager)
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(
                    destination,
                    withItemAt: temporary,
                    backupItemName: nil,
                    options: [.usingNewMetadataOnly]
                )
            } else {
                // Both URLs are in the same managed directory, so rename is
                // the atomic first-publication operation for a new cache key.
                try fileManager.moveItem(at: temporary, to: destination)
            }
            try fileManager.setAttributes([.modificationDate: now()], ofItemAtPath: destination.path)
        } catch {
            throw V2DeviceLocalStorageError.fileSystemFailure
        }
        // Cache cleanup is best-effort after the atomic publication. Keep the
        // file being returned even if one server-authorized object is larger
        // than the aggregate target; the upload policy still bounds a single
        // object, and a later maintenance pass may remove it.
        try? enforceCachePolicy(excluding: destination)
        return .init(mediaID: media.mediaID, fileURL: destination)
    }

    func discard(_ media: V2MediaReference) async {
        let candidate = cacheURL(for: media.mediaID).standardizedFileURL
        guard candidate.deletingLastPathComponent() == directory else { return }
        try? fileManager.removeItem(at: candidate)
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

    /// Activation-time maintenance removes interrupted transfers, expired
    /// entries, then least-recently-downloaded files until both capacity caps
    /// are satisfied. It only examines direct regular children with the cache
    /// extension and never follows a path outside the managed directory.
    func performMaintenance() {
        discardOrphanedTemporaryFiles()
        try? enforceCachePolicy(excluding: nil)
    }

    private func enforceCachePolicy(excluding retainedURL: URL?) throws {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        let entries = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: []
        ).compactMap { url -> MediaCacheEntry? in
            let candidate = url.standardizedFileURL
            guard candidate.deletingLastPathComponent() == directory,
                  candidate.pathExtension == "media"
            else { return nil }
            let values = try candidate.resourceValues(forKeys: keys)
            guard values.isRegularFile == true else { return nil }
            return .init(
                url: candidate,
                byteCount: max(0, Int64(values.fileSize ?? 0)),
                lastAccessedAt: values.contentModificationDate ?? .distantPast
            )
        }
        let expirationBoundary = now().addingTimeInterval(-cachePolicy.maximumAge)
        var retainedEntries: [MediaCacheEntry] = []
        for entry in entries {
            if entry.lastAccessedAt < expirationBoundary,
               entry.url != retainedURL?.standardizedFileURL {
                do {
                    try fileManager.removeItem(at: entry.url)
                } catch {
                    retainedEntries.append(entry)
                }
            } else {
                retainedEntries.append(entry)
            }
        }

        var totalBytes = retainedEntries.reduce(Int64(0)) { partial, entry in
            partial.addingReportingOverflow(entry.byteCount).overflow
                ? Int64.max
                : partial + entry.byteCount
        }
        var totalEntries = retainedEntries.count
        for entry in retainedEntries.sorted(by: MediaCacheEntry.olderFirst) {
            guard totalEntries > cachePolicy.maximumEntryCount || totalBytes > cachePolicy.maximumByteCount else { break }
            guard entry.url != retainedURL?.standardizedFileURL else { continue }
            do {
                try fileManager.removeItem(at: entry.url)
                totalEntries -= 1
                totalBytes = max(0, totalBytes - entry.byteCount)
            } catch {
                continue
            }
        }
    }

    private func cacheURL(for mediaID: MediaID) -> URL {
        let digest = SHA256.hash(data: Data(mediaID.rawValue.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return directory.appendingPathComponent(digest + ".media", isDirectory: false)
    }
}

private struct MediaCacheEntry {
    let url: URL
    let byteCount: Int64
    let lastAccessedAt: Date

    static func olderFirst(_ lhs: Self, _ rhs: Self) -> Bool {
        lhs.lastAccessedAt == rhs.lastAccessedAt
            ? lhs.url.lastPathComponent < rhs.url.lastPathComponent
            : lhs.lastAccessedAt < rhs.lastAccessedAt
    }
}
